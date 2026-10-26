import Foundation
import Testing
@testable import EbbCore

private actor FakeNotifier: Notifier {
    private(set) var authorization: Bool?
    private let grants: Bool
    private(set) var requests = 0
    private(set) var posted: [PoolAlert] = []

    init(authorization: Bool? = nil, grants: Bool = true) {
        self.authorization = authorization
        self.grants = grants
    }

    func isAuthorized() -> Bool? { authorization }

    func requestAuthorization() -> Bool {
        requests += 1
        authorization = grants
        return grants
    }

    func post(_ alert: PoolAlert) {
        posted.append(alert)
    }
}

private let alertNow = Date(timeIntervalSince1970: 1_793_040_000)

private func pool(weeklyFree: Double = 50, sessionFree: Double = 20, weight: Double = 40) -> PoolSummary {
    PoolSummary(
        session: WindowSummary(freePercent: sessionFree, resets: []),
        weekly: WindowSummary(freePercent: weeklyFree, resets: []),
        isPartial: false, totalWeight: weight, readableShare: 1
    )
}

private func runningOut(_ minutes: ClosedRange<Double>) -> PoolForecast {
    PoolForecast(session: Pace.Forecast(outlook: .runsOut(within: (minutes.lowerBound * 60)...(minutes.upperBound * 60)), basis: 1800))
}

private let lasting = PoolForecast(session: Pace.Forecast(outlook: .lasts, basis: 1800))

/// Drives the tracker one call at a time; the continuous clock follows the wall clock unless changed.
private struct AlertRun {
    var tracker = AlertTracker()
    var now = alertNow
    var uptime: TimeInterval = 10_000
    var accounts: [String: (used: Double, resetsAt: Date?, readAt: Date)] = [:]
    var weights: [String: Double] = ["a": 20, "b": 20]

    mutating func tick(_ seconds: TimeInterval) {
        now += seconds
        uptime += seconds
    }

    /// A fresh reading of `account`, taken now.
    mutating func read(_ account: String, used: Double, resetsAt: Date?) {
        accounts[account] = (used, resetsAt, now)
    }

    mutating func alerts(_ forecast: PoolForecast? = nil, weeklyFree: Double = 50, sessionFree: Double = 20) -> [PoolAlert] {
        let list = accounts.keys.sorted().map { id in
            let account = accounts[id]!
            return PoolAccount(id: "\(id)@example.com", weight: weights[id] ?? 20, limits: [UsageLimit(kind: .weeklyAll, usedPercent: account.used, resetsAt: account.resetsAt)], readAt: account.readAt)
        }
        let total = list.reduce(0) { $0 + $1.weight }
        return tracker.alerts(pool: "claude", title: "Claude", short: .fiveHours, summary: pool(weeklyFree: weeklyFree, sessionFree: sessionFree, weight: total), forecast: forecast, accounts: list, now: now, uptime: uptime)
    }

}

@Suite struct RunOutAlertTests {
    @Test func aRunOutAlertFiresOncePerCycleAndRearmsAfterThePoolLasts() {
        var run = AlertRun()

        let first = run.alerts(runningOut(20...20))
        #expect(first.map(\.title) == ["Claude 5-hour pool about to run out"])
        #expect(first.first?.body == "About 20 min left at this pace.")
        run.tick(300)
        #expect(run.alerts(runningOut(15...15)).isEmpty)
        run.tick(300)
        #expect(run.alerts(nil).isEmpty)
        run.tick(300)
        #expect(run.alerts(runningOut(10...10)).isEmpty)

        run.tick(300)
        #expect(run.alerts(lasting).isEmpty)
        run.tick(300)
        #expect(run.alerts(runningOut(25...25)).count == 1)
    }

    @Test func aRunOutStillUnderWayAfterAWholeWindowAlertsAgain() {
        var run = AlertRun()
        #expect(run.alerts(runningOut(20...20)).count == 1)
        run.tick(5 * 3600)
        #expect(run.alerts(runningOut(20...20)).count == 1)
    }

    @Test func capacityComingBackStartsANewCycle() {
        var run = AlertRun()
        #expect(run.alerts(runningOut(20...20), sessionFree: 15).count == 1)
        run.tick(3600)
        #expect(run.alerts(runningOut(200...200), sessionFree: 55).isEmpty)
        run.tick(2 * 3600)
        #expect(run.alerts(runningOut(25...25), sessionFree: 12).count == 1)
    }

    @Test func aRangeThatMayLastPastHalfAnHourStaysQuiet() {
        var run = AlertRun()
        #expect(run.alerts(runningOut(20...50)).isEmpty)
        #expect(run.alerts(runningOut(45...45)).isEmpty)
    }

    @Test func aRelaunchNeverRepeatsARunOutAlert() throws {
        var run = AlertRun()
        #expect(run.alerts(runningOut(20...20)).count == 1)
        run.tracker = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(run.tracker))
        run.tick(60)
        #expect(run.alerts(runningOut(18...18)).isEmpty)
    }
}

@Suite struct WeeklyBackAlertTests {
    private let boundary = alertNow + 3600

    /// Account a at 80% used resets in an hour; b is fresh.
    private func startedRun() -> AlertRun {
        var run = AlertRun()
        run.read("a", used: 80, resetsAt: boundary)
        run.read("b", used: 0, resetsAt: alertNow + 5 * 86400)
        #expect(run.alerts().isEmpty)
        return run
    }

    @Test func aWeeklyResetLandingAlertsOnce() {
        var run = startedRun()
        run.tick(3630)

        let landed = run.alerts(weeklyFree: 99)
        #expect(landed.map(\.title) == ["Claude weekly back +40%"])
        #expect(landed.first?.body == "99% of the weekly pool is free.")
        run.tick(30)
        #expect(run.alerts(weeklyFree: 99).isEmpty)
    }

    @Test func aResetObservedTwiceAlertsOnce() {
        var run = startedRun()
        run.tick(3630)
        #expect(run.alerts().count == 1)

        // The old window's reading again, then once more with its reset a few seconds later.
        run.tick(15)
        run.read("a", used: 80, resetsAt: boundary)
        #expect(run.alerts().isEmpty)
        run.tick(1)
        run.read("a", used: 80, resetsAt: run.now + 3)
        #expect(run.alerts().isEmpty)
        run.tick(10)
        #expect(run.alerts().isEmpty)
    }

    /// syrtis#367: the reset time drifts by seconds around the boundary.
    @Test func aResetTimeDriftingBySecondsIsOneReset() {
        var run = startedRun()
        run.tick(3602)
        run.read("a", used: 80, resetsAt: boundary + 5)
        #expect(run.alerts().isEmpty)
        run.tick(10)
        #expect(run.alerts().count == 1)
    }

    /// CodexBar#2230: a refill that keeps its reset time, then a stale pre-refill value, then the refill again.
    @Test func aRefillWithAStaleReboundAlertsOnce() {
        var run = startedRun()
        var titles: [String] = []
        for used in [0.0, 80, 0, 2] {
            run.tick(15)
            run.read("a", used: used, resetsAt: boundary)
            titles += run.alerts().map(\.title)
        }
        #expect(titles == ["Claude weekly back +39%"])
    }

    /// CodexBar#2222: one bogus near-zero sample.
    @Test func aBogusLowSampleNeverAlerts() {
        var run = startedRun()
        for used in [0.0, 80, 81] {
            run.tick(15)
            run.read("a", used: used, resetsAt: boundary)
            #expect(run.alerts().isEmpty)
        }
    }

    @Test func anOldReadingFollowedByAFreshOneIsNotARefill() {
        var run = AlertRun()
        run.read("a", used: 80, resetsAt: alertNow + 5 * 86400)
        run.accounts["a"]?.readAt = alertNow - 3 * 86400
        _ = run.alerts()

        run.tick(60)
        run.read("a", used: 3, resetsAt: alertNow + 12 * 86400)
        #expect(run.alerts().isEmpty)
    }

    @Test func aClockJumpPastTheResetIsNotARefill() {
        var run = startedRun()
        run.now += 2 * 3600
        run.uptime += 30
        #expect(run.alerts().isEmpty)
    }

    @Test func aResetPassedDuringSleepStillAlertsAfterWaking() {
        var run = startedRun()
        run.tick(3 * 3600)
        #expect(run.alerts().count == 1)
    }

    @Test func anAccountRejoiningAfterItsResetIsNotARefill() {
        var run = startedRun()
        run.accounts["a"] = nil
        for _ in 0..<3 {
            run.tick(30)
            _ = run.alerts()
        }

        run.tick(3600)
        run.read("a", used: 0, resetsAt: boundary + 7 * 86400)
        #expect(run.alerts().isEmpty)
    }

    @Test func returnsSecondsApartAddUpToOneAlert() {
        var run = AlertRun()
        run.weights = ["a": 20, "b": 20, "c": 20]
        for (account, used) in [("a", 20.0), ("b", 25), ("c", 30)] {
            run.read(account, used: used, resetsAt: boundary + Double(account.unicodeScalars.first!.value - 97) * 30)
        }
        _ = run.alerts()
        run.tick(3590)

        var titles: [String] = []
        for _ in 0..<4 {
            run.tick(30)
            titles += run.alerts().map(\.title)
        }
        run.tick(3600)
        titles += run.alerts().map(\.title)

        #expect(titles == ["Claude weekly back +25%"])
    }

    @Test func anAccountMissingFromOnePollKeepsItsReset() {
        var run = startedRun()
        let a = run.accounts["a"]
        run.tick(3540)
        _ = run.alerts()
        run.tick(30)
        run.accounts["a"] = nil
        _ = run.alerts()
        run.accounts["a"] = a
        run.tick(60)

        #expect(run.alerts().count == 1)
    }

    @Test func smallWeeklyReturnsStayQuiet() {
        var run = AlertRun()
        run.read("a", used: 15, resetsAt: alertNow + 60)
        run.read("b", used: 0, resetsAt: alertNow + 5 * 86400)
        _ = run.alerts()
        run.tick(120)
        #expect(run.alerts().isEmpty)
    }

    @Test func aResetThatLandedLongAgoWhileAsleepIsNotNews() {
        var run = startedRun()
        run.tick(8 * 3600)
        #expect(run.alerts().isEmpty)
    }

    @Test func aRelaunchNeverRepeatsAWeeklyAlert() throws {
        var run = startedRun()
        run.tick(3630)
        #expect(run.alerts().count == 1)

        run.tracker = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(run.tracker))
        run.read("a", used: 80, resetsAt: run.now + 5)
        run.tick(10)
        #expect(run.alerts().isEmpty)
    }

    @Test func theSavedTrackerNeverHoldsAnEmail() throws {
        let run = startedRun()
        let saved = String(decoding: try JSONEncoder().encode(run.tracker), as: UTF8.self)
        #expect(!saved.contains("example.com"))
    }
}

@MainActor
@Suite struct AlertDeliveryTests {
    private let alert = PoolAlert(id: "a", title: "t", body: "b")

    @Test func permissionIsAskedOnlyWhenTheFirstAlertIsDue() async {
        let notifier = FakeNotifier()
        let delivery = AlertDelivery(notifier: notifier, isEnabled: { true })

        await delivery.deliver([])
        #expect(await notifier.requests == 0)

        await delivery.deliver([alert])
        await delivery.deliver([alert])
        #expect(await notifier.requests == 1)
        #expect(await notifier.posted.count == 2)
    }

    @Test func aDeniedPermissionPostsNothing() async {
        let notifier = FakeNotifier(grants: false)
        await AlertDelivery(notifier: notifier, isEnabled: { true }).deliver([alert])
        #expect(await notifier.posted.isEmpty)
    }

    @Test func alertsTurnedOffNeverAsk() async {
        let notifier = FakeNotifier()
        await AlertDelivery(notifier: notifier, isEnabled: { false }).deliver([alert])
        #expect(await notifier.requests == 0)
        #expect(await notifier.posted.isEmpty)
    }

    @Test func turningAlertsOnAsksRightAway() async {
        let notifier = FakeNotifier()
        #expect(await AlertDelivery(notifier: notifier, isEnabled: { true }).enable())
        #expect(await notifier.requests == 1)
    }
}
