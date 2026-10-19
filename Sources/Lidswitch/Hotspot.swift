import CoreLocation
import CoreWLAN
import Foundation
import Network
import Security

/// Q10: the iPhone hotspot to fall back to. Name in UserDefaults, password in the login Keychain.
/// No subprocesses and no polling: network changes arrive as events, joins run only when asked.
enum Hotspot {
    enum Result { case joined, notFound, noPassword, failed(String) }

    static let service = "com.arhanbarve.lidswitch.hotspot"
    private static let key = "hotspotSSID"
    private static let queue = DispatchQueue(label: service)
    private static let monitor = NWPathMonitor()
    private static let location = CLLocationManager()

    static var ssid: String? { UserDefaults.standard.string(forKey: key) }

    /// nil = not on Wi-Fi, or macOS won't say (needs Location Services).
    static func currentSSID() -> String? { CWWiFiClient.shared().interface()?.ssid() }

    /// macOS only reveals Wi-Fi names to apps with Location Services. Location itself is never read.
    static var locationDenied: Bool {
        location.authorizationStatus == .denied || location.authorizationStatus == .restricted
    }

    /// Event whenever the Mac gains or loses its last working network (any interface).
    static func onNetworkChange(_ handler: @escaping (Bool) -> Void) {
        monitor.pathUpdateHandler = { handler($0.status == .satisfied) }
        monitor.start(queue: .main)
    }

    private static func item(_ ssid: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: ssid]
    }

    private static func password(_ ssid: String) -> String? {
        var q = item(ssid)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(ssid: String, password: String) -> Bool {
        forget()
        var q = item(ssid)
        q[kSecValueData] = Data(password.utf8)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(ssid, forKey: key)
        location.requestWhenInUseAuthorization()
        return true
    }

    static func forget() {
        if let old = ssid { SecItemDelete(item(old) as CFDictionary) }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Keychain read, Wi-Fi scan and join all block (the scan for seconds; the Keychain for as long
    /// as a dialog nobody can see stays up), so they run off the main thread: the timer, battery
    /// and heat cutoffs must never wait on this. `done` is called on the main thread.
    static func join(_ ssid: String, done: @escaping (Result) -> Void) {
        queue.async {
            let r = attempt(ssid)
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func attempt(_ ssid: String) -> Result {
        guard let pw = password(ssid) else { return .noPassword }
        guard let wifi = CWWiFiClient.shared().interface() else { return .failed("no Wi-Fi interface") }
        do {
            // Scan by name: the join works with what comes back even when macOS hides its name.
            guard let net = try wifi.scanForNetworks(withSSID: Data(ssid.utf8)).first else { return .notFound }
            try wifi.associate(to: net, password: pw)
            return .joined
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
