import Foundation

/// Mirrors ProcessInfo.ThermalState ordering so the policy stays pure and testable.
public enum Thermal: Int, Comparable, Sendable {
    case nominal = 0, fair, serious, critical
    public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
}

/// Everything the policy needs to know. `nil` means "could not read it".
public struct Snapshot: Equatable, Sendable {
    public var now: Date
    public var flagOn: Bool?          // kernel SleepDisabled
    public var owned: Bool            // lidswitch turned it on in this process lifetime
    public var deadline: Date?        // auto-off time, set whenever owned
    public var onBattery: Bool?
    public var batteryPercent: Int?
    public var lidClosed: Bool?
    public var thermal: Thermal
    public var lowBatteryOK: Bool     // this session was started with "anyway (low battery)"

    public init(now: Date, flagOn: Bool?, owned: Bool, deadline: Date?, onBattery: Bool?,
                batteryPercent: Int?, lidClosed: Bool?, thermal: Thermal, lowBatteryOK: Bool = false) {
        self.lowBatteryOK = lowBatteryOK
        self.now = now; self.flagOn = flagOn; self.owned = owned; self.deadline = deadline
        self.onBattery = onBattery; self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed; self.thermal = thermal
    }
}

public enum OffReason: String, Equatable, Sendable {
    case unowned = "sleep was disabled outside lidswitch"
    case flagUnreadable = "could not read the SleepDisabled flag"
    case noDeadline = "no auto-off time was set"
    case timer = "timer expired"
    case battery = "battery at or below cutoff"
    case powerUnknown = "could not read battery / power source"
    case thermalBag = "Mac is warm (fair) with lid closed on battery"
    case thermal = "Mac is hot (serious or worse)"
}

public enum Refusal: String, Equatable, Error, Sendable {
    case badDuration = "duration not allowed"
    case battery = "battery at or below cutoff"
    case powerUnknown = "could not read battery / power source"
    case thermal = "Mac is too warm"
    case flagUnreadable = "could not read the SleepDisabled flag"
}

public enum Policy {
    public static let batteryCutoff = 20
    /// Cutoff for a session you started knowing the battery was low. Never lower than this.
    public static let batteryFloor = 5

    public static func batteryCutoff(_ s: Snapshot) -> Int { s.lowBatteryOK ? batteryFloor : batteryCutoff }
    public static let allowedDurations: [TimeInterval] = [30, 60, 120, 240, 480].map { $0 * 60 }
    public static let defaultDuration: TimeInterval = 120 * 60
    public static let maxRemaining: TimeInterval = 480 * 60
    public static let extendBy: TimeInterval = 60 * 60
    public static let warnBefore: TimeInterval = 5 * 60

    /// Should an ON flag be turned off right now? Fail-safe: anything unknown → off.
    public static func evaluate(_ s: Snapshot) -> OffReason? {
        guard let flagOn = s.flagOn else { return .flagUnreadable }
        guard flagOn else { return nil }
        guard s.owned else { return .unowned }
        guard let deadline = s.deadline else { return .noDeadline }
        if s.now >= deadline { return .timer }
        guard let onBattery = s.onBattery else { return .powerUnknown }
        if onBattery {
            guard let pct = s.batteryPercent else { return .powerUnknown }
            if pct <= batteryCutoff(s) { return .battery }
        }
        if s.thermal >= .serious { return .thermal }
        // Lid closed on battery = probably in a bag. Unknown lid state counts as closed.
        if onBattery && s.lidClosed != false && s.thermal >= .fair { return .thermalBag }
        return nil
    }

    /// May the user turn the override on for `duration`? Same limits as evaluate, applied up front.
    public static func canTurnOn(_ s: Snapshot, duration: TimeInterval) -> Refusal? {
        guard allowedDurations.contains(duration) else { return .badDuration }
        guard s.flagOn != nil else { return .flagUnreadable }
        guard let onBattery = s.onBattery else { return .powerUnknown }
        if onBattery {
            guard let pct = s.batteryPercent else { return .powerUnknown }
            if pct <= batteryCutoff(s) { return .battery }
        }
        if s.thermal >= .serious { return .thermal }
        if onBattery && s.lidClosed != false && s.thermal >= .fair { return .thermal }
        return nil
    }

    /// Q9: keep the built-in speakers muted? Starts when the override is ON with the lid closed
    /// (unknown counts as closed); once holding, lasts until the lid reads open, even if the
    /// override has ended, so nothing plays in the gap before the Mac sleeps.
    public static func holdSpeakerMute(holding: Bool, owned: Bool, lidClosed: Bool?) -> Bool {
        lidClosed != false && (owned || holding)
    }

    public static let hotspotWait: TimeInterval = 10
    public static let hotspotBackoff: [TimeInterval] = [5, 10, 20, 30]
    public static let hotspotGiveUp: TimeInterval = 5 * 60

    /// Q10: may lidswitch join the hotspot by itself? Only while ON with the lid closed (unknown
    /// counts as closed): with the lid open you can pick a network yourself.
    public static func hotspotArmed(owned: Bool, lidClosed: Bool?) -> Bool {
        owned && lidClosed != false
    }

    /// Q10: seconds to wait before join attempt number `attempt` (0 = first) of an outage that
    /// began `elapsed` seconds ago. nil = give up: the attempt would land past the 5-min limit.
    public static func hotspotRetry(attempt: Int, elapsed: TimeInterval) -> TimeInterval? {
        let delay = attempt == 0 ? hotspotWait : hotspotBackoff[min(attempt, hotspotBackoff.count) - 1]
        return elapsed + delay <= hotspotGiveUp ? delay : nil
    }

    /// "+1h", capped so no more than 8h ever remain.
    public static func extended(_ deadline: Date, now: Date) -> Date {
        min(deadline.addingTimeInterval(extendBy), now.addingTimeInterval(maxRemaining))
    }
}
