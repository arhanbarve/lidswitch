import Darwin
import Foundation

/// Running `caffeinate` processes (started by anyone), read in-process via libproc.
/// Independent of the lid override: caffeinate only blocks idle sleep, never lid sleep (SPEC §2),
/// and nothing here touches SleepDisabled.
enum Caffeinate {
    struct Proc { let pid: pid_t; let args: [String]; let started: Date }

    static let durations: [TimeInterval] = [1, 2, 4, 8].map { $0 * 3600 }
    private static var children: [Process] = []  // keep our own children alive until reaped

    static func running() -> [Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(got, 0))).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_status != SZOMB else { return nil }  // exited, not yet reaped
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "caffeinate" else { return nil }
            return Proc(pid: pid, args: args(pid), started: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
        }
    }

    /// Arguments after argv[0], e.g. ["-dims", "-t", "86400"]. Empty if unreadable (another user's process).
    private static func args(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        // Layout: argc (Int32), exec path, NUL padding, argv..., env...
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let parts = buf[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(parts.dropFirst().prefix(Int(argc)).dropFirst())
    }

    /// Plain-English version of the flags, e.g. "-dim -t 3600" -> "screen on, no idle sleep, disk awake · 58m left".
    static func describe(_ p: Proc, now: Date = Date()) -> String {
        var flags = Set<Character>(), timeout: Int?, waitPid: pid_t?, command: String?
        var i = 0
        while i < p.args.count {
            let a = p.args[i]; i += 1
            guard a.hasPrefix("-"), a.count > 1 else { command = (a as NSString).lastPathComponent; break }
            var rest = a.dropFirst()
            while let f = rest.first {
                rest = rest.dropFirst()
                guard f == "t" || f == "w" else { flags.insert(f); continue }
                // value is the rest of this cluster ("-t60") or the next argument ("-t 60")
                let v = rest.isEmpty ? (i < p.args.count ? p.args[i] : "") : String(rest)
                if rest.isEmpty { i += 1 }
                if f == "t" { timeout = Int(v) } else { waitPid = pid_t(v) }
                break
            }
        }
        let names: [(Character, String)] = [("d", "screen on"), ("i", "no idle sleep"), ("m", "disk awake"),
                                             ("s", "no sleep on AC power"), ("u", "acts like user activity")]
        var what = names.filter { flags.contains($0.0) }.map(\.1)
        if what.isEmpty { what = ["no idle sleep"] }  // caffeinate with no flags means -i

        let until: String
        if let t = timeout {
            let left = Int(p.started.addingTimeInterval(TimeInterval(t)).timeIntervalSince(now) / 60)
            // the timer pauses while the Mac sleeps, so it can run past its wall-clock end
            until = left >= 0 ? "\(hm(left)) left" : "\(hm(t / 60)) timer, paused while Mac slept"
        } else if let w = waitPid {
            until = "until \(name(w) ?? "pid \(w)") quits"
        } else if let c = command {
            until = "while \(c) runs"
        } else {
            until = "until stopped"
        }
        return p.args.isEmpty ? "settings unknown · \(hm(Int(now.timeIntervalSince(p.started) / 60))) so far"
                              : "\(what.joined(separator: ", ")) · \(until)"
    }

    private static func hm(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
    }

    private static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// `caffeinate -dim -t secs`. No -s: a PreventSystemSleep assertion could block the sleep
    /// lidswitch requests when the override ends with the lid already shut.
    static func start(_ seconds: TimeInterval) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dim", "-t", String(Int(seconds))]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { done in DispatchQueue.main.async { children.removeAll { $0 === done } } }
        do { try p.run() } catch { return false }
        children.append(p)
        return true
    }

    static func stop(_ pid: pid_t) -> Bool { kill(pid, SIGTERM) == 0 }
}
