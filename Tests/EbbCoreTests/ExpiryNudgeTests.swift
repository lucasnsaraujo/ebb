import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
private let utc = TimeZone(identifier: "UTC")!
private let english = Locale(identifier: "en_US")

private func account(_ id: String, weight: Double = 1, weeklyUsed: Double, resetsIn hours: Double) -> PoolAccount {
    PoolAccount(id: id, weight: weight, limits: [UsageLimit(kind: .weeklyAll, usedPercent: weeklyUsed, resetsAt: now + hours * 3600)], readAt: now)
}

@Suite struct ExpiryNudgeTests {
    private func alerts(_ nudge: inout ExpiryNudge, _ accounts: [PoolAccount], forecast: Pace.Forecast? = nil, at date: Date = now) -> [PoolAlert] {
        nudge.alerts(pool: "claude", title: "Claude", accounts: accounts, totalWeight: accounts.reduce(0) { $0 + $1.weight }, forecast: forecast, now: date, timeZone: utc, locale: english)
    }

    @Test func weeklyCapacityAboutToResetUnusedSendsOneNudge() {
        var nudge = ExpiryNudge()
        let accounts = [account("a", weeklyUsed: 20, resetsIn: 20), account("b", weeklyUsed: 100, resetsIn: 30)]
        #expect(alerts(&nudge, accounts).map(\.title) == ["Claude: 40% of this week's pool resets unused tomorrow 3:34\u{202F}PM"])
    }

    @Test func aResetMoreThanADayAwayWaits() {
        var nudge = ExpiryNudge()
        #expect(alerts(&nudge, [account("a", weeklyUsed: 10, resetsIn: 30)]).isEmpty)
    }

    @Test func aSmallLeftoverIsNotWorthANudge() {
        var nudge = ExpiryNudge()
        #expect(alerts(&nudge, [account("a", weeklyUsed: 85, resetsIn: 10)]).isEmpty)
    }

    @Test func aPaceThatUsesItUpBeforeTheResetStaysQuiet() {
        var nudge = ExpiryNudge()
        let runsOut = Pace.Forecast(outlook: .runsOut(within: 3600...5 * 3600), basis: 86400)
        #expect(alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)], forecast: runsOut).isEmpty)
        let lasts = Pace.Forecast(outlook: .lasts, basis: 86400)
        #expect(alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)], forecast: lasts).count == 1)
    }

    @Test func aPaceThatRunsOutOnlyAfterTheResetStillNudges() {
        var nudge = ExpiryNudge()
        let late = Pace.Forecast(outlook: .runsOut(within: 11 * 3600...12 * 3600), basis: 86400)
        #expect(alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)], forecast: late).count == 1)
    }

    @Test func theSoonestResetDecidesWhetherThePaceUsesItUp() {
        var nudge = ExpiryNudge()
        let runsOut = Pace.Forecast(outlook: .runsOut(within: 14 * 3600...15 * 3600), basis: 86400)
        let accounts = [account("a", weeklyUsed: 20, resetsIn: 2), account("b", weeklyUsed: 20, resetsIn: 20)]
        #expect(alerts(&nudge, accounts, forecast: runsOut).count == 1)
    }

    @Test func anAccountJoiningTheWindowLaterIsTheSameCycle() {
        var nudge = ExpiryNudge()
        let accounts = [account("a", weeklyUsed: 20, resetsIn: 20), account("b", weeklyUsed: 20, resetsIn: 30)]
        #expect(alerts(&nudge, accounts).count == 1)
        #expect(alerts(&nudge, accounts, at: now + 7 * 3600).isEmpty)
    }

    @Test func eachWeeklyCycleNudgesOnce() {
        var nudge = ExpiryNudge()
        #expect(alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)]).count == 1)
        #expect(alerts(&nudge, [account("a", weeklyUsed: 31, resetsIn: 9)], at: now + 3600).isEmpty)
        let nextWeek = now + 7 * 86400
        let next = PoolAccount(id: "a", weight: 1, limits: [UsageLimit(kind: .weeklyAll, usedPercent: 30, resetsAt: nextWeek + 10 * 3600)], readAt: nextWeek)
        #expect(alerts(&nudge, [next], at: nextWeek).count == 1)
    }

    @Test func aResetTimeThatDriftsBySecondsIsTheSameCycle() {
        var nudge = ExpiryNudge()
        _ = alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)])
        #expect(alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10.01)], at: now + 60).isEmpty)
    }

    @Test func aResetTwoCalendarDaysAwayNamesItsWeekday() {
        let late = UsageLimit.parseTimestamp("2026-10-26T23:30:00+00:00")!
        #expect(ExpiryNudge.moment(late + 23 * 3600, now: late, timeZone: utc, locale: english) == "tomorrow 10:30\u{202F}PM")
        #expect(ExpiryNudge.moment(late + 25 * 3600, now: late, timeZone: utc, locale: english) == "Wed 12:30\u{202F}AM")
    }

    @Test func aRelaunchRemembersTheCycle() throws {
        var nudge = ExpiryNudge()
        _ = alerts(&nudge, [account("a", weeklyUsed: 30, resetsIn: 10)])
        var restored = try JSONDecoder().decode(ExpiryNudge.self, from: JSONEncoder().encode(nudge))
        #expect(alerts(&restored, [account("a", weeklyUsed: 30, resetsIn: 10)], at: now + 60).isEmpty)
    }
}
