import Darwin
import Foundation

/// Running `caffeinate` processes (started by anyone), read in-process via libproc.
/// Independent of the lid override: caffeinate only blocks idle sleep, never lid sleep (SPEC §2),
/// and nothing here touches SleepDisabled.
enum Caffeinate {
    struct Proc { let pid: pid_t; let args: String; let started: Date }

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

    /// Flags after argv[0], e.g. "-dims -t 86400". Empty if unreadable (another user's process).
    private static func args(_ pid: pid_t) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        // Layout: argc (Int32), exec path, NUL padding, argv..., env...
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let parts = buf[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return parts.dropFirst().prefix(Int(argc)).dropFirst().joined(separator: " ")
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
