import AppKit
import IOKit
import IOKit.ps
import LidswitchCore
import UserNotifications

// iokit_family_msg(sub_iokit_powermanagement, 0x100) — not imported into Swift.
let kClamshellStateChange: natural_t = 0xE003_4100

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static let showMenuNote = Notification.Name("com.arhanbarve.lidswitch.showMenu")
    var item: NSStatusItem!  // created once the app has finished launching, not at init
    let menu = NSMenu()

    // Owned state. Only this process may hold the flag ON (Q6).
    var owned = false
    var deadline: Date?
    var lastOff: String?
    var error: String?
    var ruleInstalled = false

    var deadlineTimer: Timer?
    var warnTimer: Timer?
    var safetyTimer: Timer?
    var notifyPort: IONotificationPortRef?
    var interest: io_object_t = 0
    var sigterm: DispatchSourceSignal?
    var noNap: NSObjectProtocol?  // held only while ON so App Nap can't delay the auto-off
    var caffeinated: [Caffeinate.Proc] = []
    var caffeineWatch: [pid_t: DispatchSourceProcess] = [:]  // exit events, so the icon updates without polling

    var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        item.menu = menu
        DistributedNotificationCenter.default().addObserver(
            forName: App.showMenuNote, object: nil, queue: .main
        ) { [weak self] _ in self?.showMenu() }
        ruleInstalled = SystemState.sudoRuleInstalled()
        if !ruleInstalled { error = "sudo rule missing, run install.sh" }

        if canNotify {
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            let extend = UNNotificationAction(identifier: "extend", title: "+1 hour")
            c.setNotificationCategories([UNNotificationCategory(
                identifier: "expiring", actions: [extend], intentIdentifiers: [])])
        }

        // Event sources. No polling except the 5-min safety check.
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().reevaluate("power")
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reevaluate("thermal") }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reevaluate("wake") }
        watchLid()

        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.reevaluate("safety") }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t

        // launchd / logout sends SIGTERM: route through normal quit so the flag goes OFF.
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        s.resume()
        sigterm = s

        Log.write("start (sudo rule \(ruleInstalled ? "ok" : "MISSING"))")
        reevaluate("launch")  // Q6: any ON found at launch is not ours → OFF.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SystemState.sleepDisabled() != false {
            SystemState.setSleepDisabled(false)
            Log.write("quit → OFF (flag now \(flagText()))")
        }
        return .terminateNow
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the menu instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMenu()
        return false
    }

    /// Drops the menu from the icon; if macOS is hiding the icon, at the mouse.
    /// A hidden item's window is 0 pt tall at (0,0) while occlusionState still says visible (macOS 27).
    func showMenu() {
        if let b = item.button, let h = b.window?.frame.height, h > 0 {
            b.performClick(nil)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func watchLid() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { ctx, _, msg, _ in
            guard msg == kClamshellStateChange else { return }
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().reevaluate("lid")
        }, Unmanaged.passUnretained(self).toOpaque(), &interest)
    }

    // MARK: policy

    func snapshot() -> Snapshot {
        let (bat, pct) = SystemState.power()
        return Snapshot(now: Date(), flagOn: SystemState.sleepDisabled(), owned: owned, deadline: deadline,
                        onBattery: bat, batteryPercent: pct, lidClosed: SystemState.lidClosed(),
                        thermal: SystemState.thermal())
    }

    func reevaluate(_ why: String) {
        let s = snapshot()
        if s.flagOn == false && owned {
            Log.write("flag turned off outside lidswitch (\(why))")
            clearOwned()
        }
        if s.flagOn != false, let reason = Policy.evaluate(s) {
            turnOff(reason.rawValue)
        }
        updateIcon()
    }

    func turnOn(_ duration: TimeInterval) {
        let s = snapshot()
        if let r = Policy.canTurnOn(s, duration: duration) {
            notify("Not turned on", r.rawValue)
            Log.write("refused ON: \(r.rawValue)")
            return
        }
        guard SystemState.setSleepDisabled(true), SystemState.sleepDisabled() == true else {
            error = "could not turn on (sudo/pmset failed)"
            Log.write("ON failed")
            SystemState.setSleepDisabled(false)  // never leave a half state
            updateIcon()
            return
        }
        error = ruleInstalled ? nil : error
        owned = true
        noNap = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "lid override auto-off timer")
        setDeadline(Date().addingTimeInterval(duration))
        Log.write("ON for \(Int(duration / 60))m, until \(deadline!)")
        updateIcon()
    }

    func turnOff(_ reason: String) {
        let ok = SystemState.setSleepDisabled(false)
        let flag = SystemState.sleepDisabled()
        clearOwned()
        if ok && flag == false {
            lastOff = "\(reason) (\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)))"
            error = ruleInstalled ? nil : error
            Log.write("OFF: \(reason)")
            if reason != "turned off by you" { notify("Lid sleep restored", reason) }
            // Lid already shut (or unknown → treat as shut): macOS won't sleep on its own.
            if SystemState.lidClosed() != false {
                Log.write("lid closed at OFF → sleep now (\(SystemState.sleepNow() ? "ok" : "FAILED"))")
            }
        } else {
            // Leave error visible; the 5-min safety check and every event will retry.
            error = "FAILED to turn off! Run: sudo pmset -a disablesleep 0"
            Log.write("OFF FAILED (\(reason)), flag=\(flagText())")
            notify("lidswitch could NOT restore lid sleep", "Run: sudo pmset -a disablesleep 0")
        }
        updateIcon()
    }

    func extend() {
        guard owned, let d = deadline else { return }
        setDeadline(Policy.extended(d, now: Date()))
        Log.write("extended until \(deadline!)")
        reevaluate("extend")
    }

    func setDeadline(_ d: Date) {
        deadline = d
        deadlineTimer?.invalidate(); warnTimer?.invalidate()
        let dt = Timer(fire: d, interval: 0, repeats: false) { [weak self] _ in self?.reevaluate("timer") }
        dt.tolerance = 5
        RunLoop.main.add(dt, forMode: .common)
        deadlineTimer = dt
        let w = d.addingTimeInterval(-Policy.warnBefore)
        if w > Date() {
            let wt = Timer(fire: w, interval: 0, repeats: false) { [weak self] _ in
                self?.notify("Lid override ends in 5 min", "Mac will sleep if the lid is closed.", extendable: true)
            }
            wt.tolerance = 30
            RunLoop.main.add(wt, forMode: .common)
            warnTimer = wt
        }
    }

    func clearOwned() {
        owned = false; deadline = nil
        if let a = noNap { ProcessInfo.processInfo.endActivity(a); noNap = nil }
        deadlineTimer?.invalidate(); warnTimer?.invalidate()
        deadlineTimer = nil; warnTimer = nil
    }

    // MARK: UI

    func flagText() -> String {
        switch SystemState.sleepDisabled() { case true?: "ON"; case false?: "OFF"; default: "UNKNOWN" }
    }

    /// In-process scan (no subprocess). Runs on every existing event; exits are watched directly.
    func refreshCaffeinate() {
        caffeinated = Caffeinate.running()
        let pids = Set(caffeinated.map(\.pid))
        for (pid, s) in caffeineWatch where !pids.contains(pid) { s.cancel(); caffeineWatch[pid] = nil }
        for pid in pids where caffeineWatch[pid] == nil {
            let s = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            s.setEventHandler { [weak self] in self?.updateIcon() }
            s.resume()
            caffeineWatch[pid] = s
        }
    }

    func updateIcon() {
        refreshCaffeinate()
        let symbol: String
        if error != nil { symbol = "exclamationmark.triangle" }
        else if owned { symbol = "cup.and.saucer.fill" }
        else if !caffeinated.isEmpty { symbol = "mug" }
        else { symbol = "moon.zzz" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "lidswitch")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateIcon()  // also refreshes `caffeinated`
        let s = snapshot()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func action(_ t: String, _ sel: Selector, _ tag: Int = 0) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; i.tag = tag; menu.addItem(i)
        }

        if owned, let d = deadline {
            let m = max(0, Int(d.timeIntervalSinceNow / 60))
            info("Lid override ON: \(m / 60)h \(m % 60)m left")
        } else {
            info("Lid override OFF (normal sleep)")
        }
        let bat = s.onBattery.map { $0 ? "battery" : "AC" } ?? "?"
        let pct = s.batteryPercent.map { "\($0)%" } ?? "?"
        let lid = s.lidClosed.map { $0 ? "closed" : "open" } ?? "?"
        info("\(bat) \(pct) · thermal \(s.thermal) · lid \(lid)")
        if let e = error { info("⚠ \(e)") }
        menu.addItem(.separator())

        if owned {
            action("+1 hour", #selector(menuExtend))
            action("Turn off now", #selector(menuOff))
        } else if ruleInstalled {
            for d in Policy.allowedDurations {
                let min = Int(d / 60)
                let label = min < 60 ? "\(min) min" : "\(min / 60) hour\(min == 60 ? "" : "s")"
                action("Stay awake \(label)\(d == Policy.defaultDuration ? " (default)" : "")", #selector(menuOn), min)
            }
        }
        if let l = lastOff { menu.addItem(.separator()); info("Last auto-off: \(l)") }

        // Caffeinate: idle sleep only. Separate from the lid override above.
        menu.addItem(.separator())
        info(caffeinated.isEmpty ? "Not caffeinated" : "Caffeinated (idle sleep only, not lid): \(caffeinated.count)")
        for c in caffeinated {
            let m = max(0, Int(Date().timeIntervalSince(c.started) / 60))
            action("Stop caffeinate \(c.args.isEmpty ? "pid \(c.pid)" : c.args) · up \(m / 60)h \(m % 60)m",
                   #selector(menuStopCaffeinate), Int(c.pid))
        }
        let sub = NSMenu()
        for d in Caffeinate.durations {
            let h = Int(d / 3600)
            let i = NSMenuItem(title: "\(h) hour\(h == 1 ? "" : "s")", action: #selector(menuCaffeinate), keyEquivalent: "")
            i.target = self; i.tag = h; sub.addItem(i)
        }
        let c = NSMenuItem(title: "Caffeinate (caffeinate -dim)", action: nil, keyEquivalent: "")
        c.submenu = sub
        menu.addItem(c)

        menu.addItem(.separator())
        action("Quit (restores lid sleep)", #selector(menuQuit))
    }

    @objc func menuCaffeinate(_ i: NSMenuItem) {
        let ok = Caffeinate.start(TimeInterval(i.tag * 3600))
        Log.write("caffeinate \(i.tag)h \(ok ? "started" : "FAILED to start")")
        updateIcon()
    }
    @objc func menuStopCaffeinate(_ i: NSMenuItem) {
        let ok = Caffeinate.stop(pid_t(i.tag))
        Log.write("caffeinate pid \(i.tag) stop \(ok ? "sent" : "FAILED")")
    }
    @objc func menuOn(_ i: NSMenuItem) { turnOn(TimeInterval(i.tag * 60)) }
    @objc func menuOff() { turnOff("turned off by you") }
    @objc func menuExtend() { extend() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: notifications

    func notify(_ title: String, _ body: String, extendable: Bool = false) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        if extendable { c.categoryIdentifier = "expiring" }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if r.actionIdentifier == "extend" { DispatchQueue.main.async { self.extend() } }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// One copy only. Two copies each see the other's ON as "not ours" and turn it off (log, 2026-10-04).
// A second launch (Spotlight, Finder, dev build) shows the running copy's menu and exits 0, before
// any quit handler that would touch the flag. flock is released by the kernel when we die.
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("com.arhanbarve.lidswitch.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(
        App.showMenuNote, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
