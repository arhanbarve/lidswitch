import Foundation
import IOKit
import IOKit.ps
import LidswitchCore

/// In-process reads (no subprocesses) and the one privileged write.
enum SystemState {
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    private static func rootDomainBool(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return v as? Bool
    }

    static func sleepDisabled() -> Bool? { rootDomainBool("SleepDisabled") }
    static func lidClosed() -> Bool? { rootDomainBool("AppleClamshellState") }

    /// (onBattery, percent). Either can be nil if unreadable.
    static func power() -> (Bool?, Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, nil) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery: Bool? = switch type {
        case kIOPSBatteryPowerValue: true
        case kIOPSACPowerValue: false
        default: nil
        }
        var percent: Int?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = cur * 100 / max
        }
        return (onBattery, percent)
    }

    static func thermal() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical  // unknown → most restrictive
        }
    }

    /// Runs `sudo -n pmset -a disablesleep 0|1`. Never prompts. Returns exit status == 0.
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        run(sudo, ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"])
    }

    /// True if the sudoers rule for both exact commands is installed (checked once at launch).
    static func sudoRuleInstalled() -> Bool {
        run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "0"])
            && run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "1"])
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/lidswitch.log")

    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
