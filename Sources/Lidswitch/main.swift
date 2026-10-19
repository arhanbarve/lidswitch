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
    var speakerWasMuted: Bool?  // non-nil while we hold the speakers muted (Q9): the state to put back

    var lowBatteryOK = false       // this session was started with "anyway (low battery)": stops at 5%, not 20%

    // Q10 hotspot failover.
    var online = true              // the Mac has a working network (any interface)
    var outageStart: Date?         // set while a join cycle is running, or has given up, for this outage
    var hotspotAttempts = 0
    var hotspotTimer: Timer?       // exists only during an outage
    var hotspotJoining = false
    var hotspotJoinedAt: Date?     // we joined it and, as far as we know, are still on it
    var hotspotTold = false        // the lid-open notification for hotspotJoinedAt was shown
    var hotspotNote: String?       // why the last join did not work

    var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        item.menu = menu
        DistributedNotificationCenter.default().addObserver(
            forName: App.showMenuNote, object: nil, queue: .main
        ) { [weak self] _ in self?.showMenu() }
        // Never shown (menu bar only app); it exists so ⌘V/⌘C/⌘X/⌘A work in the hotspot dialog.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
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
        Speaker.onMuteChange { [weak self] in self?.syncSpeaker() }
        Hotspot.onNetworkChange { [weak self] up in
            self?.online = up
            self?.syncHotspot()
        }

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
        if speakerWasMuted == false { Speaker.setMuted(false) }
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
                        thermal: SystemState.thermal(), lowBatteryOK: lowBatteryOK)
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
        syncSpeaker()
        syncHotspot()
        updateIcon()
    }

    /// Q10: Wi-Fi gone while ON with the lid closed → join the iPhone hotspot. Called on every event
    /// and on every network change. Never touches the override, and never leaves a network.
    func syncHotspot() {
        let lid = SystemState.lidClosed()
        if lid == false, let at = hotspotJoinedAt, !hotspotTold {
            hotspotTold = true
            notify("On your iPhone hotspot", "Joined at \(clock(at)) while the lid was closed. Switch Wi-Fi yourself when you're ready.")
        }
        guard Hotspot.ssid != nil, !online, Policy.hotspotArmed(owned: owned, lidClosed: lid) else {
            if outageStart != nil { Log.write("hotspot: stopped trying (\(online ? "network is back" : "lid open or override off"))") }
            outageStart = nil; hotspotAttempts = 0
            hotspotTimer?.invalidate(); hotspotTimer = nil
            return
        }
        guard outageStart == nil else { return }  // this outage already has a cycle running, or gave up
        outageStart = Date()
        Log.write("network lost with lid closed → hotspot in \(Int(Policy.hotspotWait))s if it stays down")
        scheduleHotspot()
    }

    func scheduleHotspot() {
        guard let start = outageStart else { return }
        guard let delay = Policy.hotspotRetry(attempt: hotspotAttempts, elapsed: Date().timeIntervalSince(start)) else {
            Log.write("hotspot: gave up after \(hotspotAttempts) tries (\(hotspotNote ?? "no reason recorded"))")
            notify("Hotspot not joined", "Gave up after 5 min. The lid override is still on.")
            return
        }
        hotspotTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tryHotspot() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        hotspotTimer = t
    }

    func tryHotspot() {
        guard outageStart != nil, !hotspotJoining, let ssid = Hotspot.ssid else { return }
        hotspotJoining = true
        hotspotAttempts += 1
        let n = hotspotAttempts
        Hotspot.join(ssid) { [weak self] result in
            guard let self else { return }
            self.hotspotJoining = false
            switch result {
            case .joined:
                self.hotspotJoinedAt = Date(); self.hotspotTold = false; self.hotspotNote = nil
            case .notFound: self.hotspotNote = "hotspot not found (phone nearby, hotspot allowed?)"
            case .noPassword: self.hotspotNote = "hotspot password unreadable, set it again"
            case .failed(let why): self.hotspotNote = "hotspot join failed: \(why)"
            }
            Log.write("hotspot try \(n): \(self.hotspotNote ?? "joined")")
            // Joined but still offline (no cellular?) is retried like any other miss.
            self.scheduleHotspot()
        }
    }

    func clock(_ d: Date) -> String {
        DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
    }

    /// Q9: no sound from the built-in speakers while ON with the lid closed. Called on every event
    /// and whenever the mute changes, so an unmute from anywhere is undone at once.
    func syncSpeaker() {
        let hold = Policy.holdSpeakerMute(holding: speakerWasMuted != nil, owned: owned,
                                          lidClosed: SystemState.lidClosed())
        if hold {
            guard let muted = Speaker.muted() else { return }
            let first = speakerWasMuted == nil
            if first { speakerWasMuted = muted }
            if !muted {
                let ok = Speaker.setMuted(true)
                Log.write("\(first ? "ON with lid closed" : "speakers unmuted with lid closed") → muted (\(ok ? "ok" : "FAILED"))")
            }
        } else if let was = speakerWasMuted {
            speakerWasMuted = nil
            if !was { Log.write("lid open → speakers unmuted (\(Speaker.setMuted(false) ? "ok" : "FAILED"))") }
        }
    }

    func turnOn(_ duration: TimeInterval, lowBatteryOK low: Bool = false) {
        var s = snapshot()
        s.lowBatteryOK = low
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
        lowBatteryOK = low
        noNap = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "lid override auto-off timer")
        setDeadline(Date().addingTimeInterval(duration))
        Log.write("ON for \(Int(duration / 60))m, until \(deadline!)\(low ? " (low battery accepted, stops at \(Policy.batteryFloor)%)" : "")")
        syncSpeaker()
        syncHotspot()
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
        syncHotspot()
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
        owned = false; deadline = nil; lowBatteryOK = false
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
            // Battery at or below 20%: the same choices, but picking one accepts running down to 5%.
            let low = Policy.canTurnOn(s, duration: Policy.defaultDuration) == .battery
                && (s.batteryPercent ?? 0) > Policy.batteryFloor
            if low { info("Battery low. These stop at \(Policy.batteryFloor)% instead of \(Policy.batteryCutoff)%:") }
            for d in Policy.allowedDurations {
                let min = Int(d / 60)
                let label = min < 60 ? "\(min) min" : "\(min / 60) hour\(min == 60 ? "" : "s")"
                if low {
                    action("Stay awake \(label) anyway (low battery)", #selector(menuOnLow), min)
                } else {
                    action("Stay awake \(label)\(d == Policy.defaultDuration ? " (default)" : "")", #selector(menuOn), min)
                }
            }
        }
        if let l = lastOff { menu.addItem(.separator()); info("Last auto-off: \(l)") }

        // Caffeinate: idle sleep only. Separate from the lid override above.
        menu.addItem(.separator())
        info(caffeinated.isEmpty ? "Caffeinate: off"
                                 : "Caffeinate: \(caffeinated.count) running (closing the lid still sleeps)")
        for c in caffeinated {
            action("Stop: \(Caffeinate.describe(c))", #selector(menuStopCaffeinate), Int(c.pid))
            menu.items.last?.toolTip = "caffeinate \(c.args.joined(separator: " ")) (pid \(c.pid))"
        }
        let sub = NSMenu()
        for d in Caffeinate.durations {
            let h = Int(d / 3600)
            let i = NSMenuItem(title: "\(h) hour\(h == 1 ? "" : "s")", action: #selector(menuCaffeinate), keyEquivalent: "")
            i.target = self; i.tag = h; sub.addItem(i)
        }
        let c = NSMenuItem(title: "Caffeinate (screen on, no idle sleep)", action: nil, keyEquivalent: "")
        c.toolTip = "Runs caffeinate -dim -t <hours>. Closing the lid still sleeps the Mac."
        c.submenu = sub
        menu.addItem(c)

        // Hotspot failover (Q10).
        menu.addItem(.separator())
        if let ssid = Hotspot.ssid {
            if let cur = Hotspot.currentSSID(), cur != ssid { hotspotJoinedAt = nil }  // you moved off it
            info("Hotspot if Wi-Fi drops (lid closed): \(ssid)")
            if let at = hotspotJoinedAt { info("On hotspot since \(clock(at)) (joined by lidswitch)") }
            if let n = hotspotNote { info("⚠ \(n)") }
            if Hotspot.locationDenied { info("⚠ Location Services off for lidswitch: hotspot may not be found") }
            action("Change hotspot…", #selector(menuSetHotspot))
            action("Forget hotspot", #selector(menuForgetHotspot))
        } else {
            action("Set hotspot for when Wi-Fi drops…", #selector(menuSetHotspot))
        }

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
    @objc func menuSetHotspot() {
        let name = NSTextField(string: Hotspot.ssid ?? "")
        name.placeholderString = "Hotspot name, exactly as the iPhone shows it"
        name.frame = NSRect(x: 0, y: 32, width: 280, height: 24)
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        pass.placeholderString = "Hotspot password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        fields.addSubview(name); fields.addSubview(pass)
        name.nextKeyView = pass

        let a = NSAlert()
        a.messageText = "iPhone hotspot"
        a.informativeText = "Joined by itself if Wi-Fi stays down for \(Int(Policy.hotspotWait)) seconds while the lid override is on and the lid is closed. The password is kept in your Keychain."
        a.accessoryView = fields
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let ssid = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, !pass.stringValue.isEmpty else {
            notify("Hotspot not saved", "Both the name and the password are needed.")
            return
        }
        let ok = Hotspot.save(ssid: ssid, password: pass.stringValue)
        hotspotNote = ok ? nil : "could not save the hotspot password to the Keychain"
        hotspotJoinedAt = nil
        Log.write("hotspot set to \"\(ssid)\" (\(ok ? "ok" : "Keychain save FAILED"))")
        syncHotspot()
    }
    @objc func menuForgetHotspot() {
        Hotspot.forget()
        hotspotNote = nil; hotspotJoinedAt = nil
        Log.write("hotspot forgotten")
        syncHotspot()
    }
    @objc func menuOn(_ i: NSMenuItem) { turnOn(TimeInterval(i.tag * 60)) }
    @objc func menuOnLow(_ i: NSMenuItem) { turnOn(TimeInterval(i.tag * 60), lowBatteryOK: true) }
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
