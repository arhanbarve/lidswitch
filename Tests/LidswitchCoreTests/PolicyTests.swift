import XCTest
@testable import LidswitchCore

final class PolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Owned, ON, on AC, lid open, cool, 1h left — the "all fine" baseline.
    func ok() -> Snapshot {
        Snapshot(now: t0, flagOn: true, owned: true, deadline: t0.addingTimeInterval(3600),
                 onBattery: false, batteryPercent: 80, lidClosed: false, thermal: .nominal)
    }

    func testBaselineKeepsOn() { XCTAssertNil(Policy.evaluate(ok())) }

    func testFlagOffNeedsNothing() {
        var s = ok(); s.flagOn = false; s.owned = false
        XCTAssertNil(Policy.evaluate(s))
    }

    // Q6: ON that lidswitch didn't start is killed (manual pmset, crash-relaunch orphan).
    func testUnownedOnIsKilled() {
        var s = ok(); s.owned = false
        XCTAssertEqual(Policy.evaluate(s), .unowned)
    }

    // Restrictive: unknowns fail to OFF.
    func testUnreadableFlagIsKilled() {
        var s = ok(); s.flagOn = nil
        XCTAssertEqual(Policy.evaluate(s), .flagUnreadable)
    }
    func testMissingDeadlineIsKilled() {
        var s = ok(); s.deadline = nil
        XCTAssertEqual(Policy.evaluate(s), .noDeadline)
    }
    func testUnknownPowerSourceIsKilled() {
        var s = ok(); s.onBattery = nil
        XCTAssertEqual(Policy.evaluate(s), .powerUnknown)
    }
    func testUnknownBatteryPercentOnBatteryIsKilled() {
        var s = ok(); s.onBattery = true; s.batteryPercent = nil
        XCTAssertEqual(Policy.evaluate(s), .powerUnknown)
    }

    // Q2: timer.
    func testTimerExpiryExactlyAtDeadline() {
        var s = ok(); s.now = s.deadline!
        XCTAssertEqual(Policy.evaluate(s), .timer)
    }
    func testOneSecondBeforeDeadlineKeepsOn() {
        var s = ok(); s.now = s.deadline!.addingTimeInterval(-1)
        XCTAssertNil(Policy.evaluate(s))
    }

    // Q1: battery ≤ 20% on battery.
    func testBatteryCutoffBoundary() {
        var s = ok(); s.onBattery = true
        s.batteryPercent = 21; XCTAssertNil(Policy.evaluate(s))
        s.batteryPercent = 20; XCTAssertEqual(Policy.evaluate(s), .battery)
        s.batteryPercent = 0; XCTAssertEqual(Policy.evaluate(s), .battery)
    }
    func testLowBatteryOnACIsFine() {
        var s = ok(); s.batteryPercent = 5
        XCTAssertNil(Policy.evaluate(s))
    }
    // T7: unplugging is not a trigger by itself.
    func testUnplugHealthyBatteryKeepsOn() {
        var s = ok(); s.onBattery = true; s.batteryPercent = 90
        XCTAssertNil(Policy.evaluate(s))
    }

    // Q8: heat.
    func testSeriousAlwaysKills() {
        var s = ok(); s.thermal = .serious
        XCTAssertEqual(Policy.evaluate(s), .thermal)
        s.thermal = .critical
        XCTAssertEqual(Policy.evaluate(s), .thermal)
    }
    func testFairOnACKeepsOn() {
        var s = ok(); s.thermal = .fair; s.lidClosed = true
        XCTAssertNil(Policy.evaluate(s))
    }
    func testFairLidOpenOnBatteryKeepsOn() {
        var s = ok(); s.thermal = .fair; s.onBattery = true
        XCTAssertNil(Policy.evaluate(s))
    }
    func testFairInBagKills() {
        var s = ok(); s.thermal = .fair; s.onBattery = true; s.lidClosed = true
        XCTAssertEqual(Policy.evaluate(s), .thermalBag)
    }
    func testFairUnknownLidOnBatteryTreatedAsBag() {
        var s = ok(); s.thermal = .fair; s.onBattery = true; s.lidClosed = nil
        XCTAssertEqual(Policy.evaluate(s), .thermalBag)
    }
    // T19: bag at fair, then plugged in → AC rule applies.
    func testBagFairThenPluggedIn() {
        var s = ok(); s.thermal = .fair; s.lidClosed = true; s.onBattery = true
        XCTAssertEqual(Policy.evaluate(s), .thermalBag)
        s.onBattery = false
        XCTAssertNil(Policy.evaluate(s))
    }

    // Turning on.
    func testCanTurnOnDefault() {
        var s = ok(); s.flagOn = false; s.owned = false; s.deadline = nil
        XCTAssertNil(Policy.canTurnOn(s, duration: Policy.defaultDuration))
    }
    func testOnlyAllowedDurations() {
        let s = ok()
        for d in Policy.allowedDurations { XCTAssertNil(Policy.canTurnOn(s, duration: d)) }
        XCTAssertEqual(Policy.canTurnOn(s, duration: 0), .badDuration)
        XCTAssertEqual(Policy.canTurnOn(s, duration: 481 * 60), .badDuration)
        XCTAssertEqual(Policy.canTurnOn(s, duration: .infinity), .badDuration)
        XCTAssertEqual(Policy.canTurnOn(s, duration: -60), .badDuration)
    }
    func testRefuseOnLowBattery() {
        var s = ok(); s.onBattery = true; s.batteryPercent = 20
        XCTAssertEqual(Policy.canTurnOn(s, duration: Policy.defaultDuration), .battery)
    }
    func testRefuseWhenHot() {
        var s = ok(); s.thermal = .serious
        XCTAssertEqual(Policy.canTurnOn(s, duration: Policy.defaultDuration), .thermal)
        s = ok(); s.thermal = .fair; s.onBattery = true; s.lidClosed = true
        XCTAssertEqual(Policy.canTurnOn(s, duration: Policy.defaultDuration), .thermal)
    }
    func testRefuseOnUnknowns() {
        var s = ok(); s.onBattery = nil
        XCTAssertEqual(Policy.canTurnOn(s, duration: Policy.defaultDuration), .powerUnknown)
        s = ok(); s.flagOn = nil
        XCTAssertEqual(Policy.canTurnOn(s, duration: Policy.defaultDuration), .flagUnreadable)
    }

    // Anything canTurnOn allows must not be killed immediately by evaluate (no flapping).
    func testNoFlapAfterTurnOn() {
        for bat in [false, true] {
            for pct in [5, 20, 21, 100] {
                for lid in [false, true] {
                    for th in [Thermal.nominal, .fair, .serious, .critical] {
                        var s = Snapshot(now: t0, flagOn: false, owned: false, deadline: nil,
                                         onBattery: bat, batteryPercent: pct, lidClosed: lid, thermal: th)
                        if Policy.canTurnOn(s, duration: Policy.defaultDuration) == nil {
                            s.flagOn = true; s.owned = true
                            s.deadline = t0.addingTimeInterval(Policy.defaultDuration)
                            XCTAssertNil(Policy.evaluate(s), "flap: bat=\(bat) pct=\(pct) lid=\(lid) th=\(th)")
                        }
                    }
                }
            }
        }
    }

    // +1h is capped at 8h remaining.
    func testExtendCapped() {
        XCTAssertEqual(Policy.extended(t0.addingTimeInterval(3600), now: t0), t0.addingTimeInterval(7200))
        XCTAssertEqual(Policy.extended(t0.addingTimeInterval(8 * 3600), now: t0), t0.addingTimeInterval(8 * 3600))
    }
}
