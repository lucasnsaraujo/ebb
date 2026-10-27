import Foundation
import Testing
@testable import EbbCore

private func listing() throws -> [ProxyAuthFile] {
    let url = try #require(Bundle.module.url(forResource: "proxy-auth-files", withExtension: "json", subdirectory: "Fixtures"))
    return try #require(ProxyAuthFile.parseList(Data(contentsOf: url)))
}

@Suite struct QuotaSignalTests {
    @Test func maxAccountSignalsBecomeSessionAndWeeklyLimits() throws {
        let max = try #require(try listing().first)
        let quota = try #require(max.quota)
        #expect(quota.limits == [
            UsageLimit(kind: .session, usedPercent: 11, resetsAt: Date(timeIntervalSince1970: 1_793_056_200)),
            UsageLimit(kind: .weeklyAll, usedPercent: 95, resetsAt: Date(timeIntervalSince1970: 1_793_149_200)),
        ])
        #expect(quota.date == UsageLimit.parseTimestamp("2026-10-26T19:51:17.589504Z"))
        #expect(max.weight == 80)
    }

    @Test func teamAccountHasOnlyTheSessionWindow() throws {
        let team = try listing()[1]
        #expect(team.quota?.limits == [UsageLimit(kind: .session, usedPercent: 6, resetsAt: Date(timeIntervalSince1970: 1_793_059_800))])
    }

    @Test func accountWithoutSignalsHasNoQuotaAndOtherProvidersAreListedApart() throws {
        let files = try listing()
        #expect(files.filter { $0.provider == "claude" }.map(\.name) == ["claude-4c515511-max@example.com.json", "claude-f11cea8c-team@example.com.json", "claude-0000-idle@example.com.json"])
        #expect(files[2].quota == nil)
        #expect(files[2].isDisabled)
        #expect(files.last?.provider == "codex")
        #expect(files.last?.quota == nil)
    }

    @Test func liveListingDecodesEveryLoginWithWeightAndQuota() throws {
        let url = try #require(Bundle.module.url(forResource: "proxy-auth-files-live", withExtension: "json", subdirectory: "Fixtures"))
        let files = try #require(ProxyAuthFile.parseList(Data(contentsOf: url)))
        #expect(files.map(\.weight) == [80, 475, 465, 390])
        #expect(files.allSatisfy { $0.quota != nil && !$0.isDisabled })
        #expect(files[0].quota?.limits.map(\.kind) == [.session, .weeklyAll])
        #expect(files[1].quota?.limits.map(\.kind) == [.session])
    }

    @Test func headerNamesAreMatchedRegardlessOfCase() {
        let limits = ClaudeProvider().limits(fromSignals: ["anthropic-ratelimit-unified-5h-utilization": "0.5"])
        #expect(limits == [UsageLimit(kind: .session, usedPercent: 50, resetsAt: nil)])
    }

    @Test func signalsWithoutTheFiveHourWindowAreNotAReading() {
        #expect(ClaudeProvider().limits(fromSignals: ["Anthropic-Ratelimit-Unified-7d-Utilization": "0.5"]) == nil)
    }
}

@Suite struct ReadingChoiceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func reading(_ used: Double, minutesAgo: Double) -> DatedLimits {
        DatedLimits(limits: [UsageLimit(kind: .session, usedPercent: used, resetsAt: nil)], date: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func freshSignalsWinOverAnOlderUsageReading() {
        let best = ReadingChoice.best(signals: reading(10, minutesAgo: 2), usage: reading(40, minutesAgo: 4), now: now)
        #expect(best?.first?.usedPercent == 10)
        #expect(ReadingChoice.hasFreshSignals(reading(10, minutesAgo: 9), now: now))
    }

    @Test func signalsOlderThanTenMinutesAskForAUsageReadingWhichWinsOnceNewer() {
        let signals = reading(10, minutesAgo: 11)
        #expect(!ReadingChoice.hasFreshSignals(signals, now: now))
        #expect(ReadingChoice.best(signals: signals, usage: reading(40, minutesAgo: 1), now: now)?.first?.usedPercent == 40)
        #expect(ReadingChoice.best(signals: signals, usage: reading(40, minutesAgo: 20), now: now)?.first?.usedPercent == 10)
    }

    @Test func staleButValidReadingIsKeptAndMarkedStale() throws {
        let choice = try #require(ReadingChoice.choose(signals: reading(10, minutesAgo: 160), usage: nil, now: now))
        #expect(choice.reading.limits.first?.usedPercent == 10)
        #expect(!choice.isFresh)
        #expect(ReadingChoice.best(signals: nil, usage: reading(40, minutesAgo: 31), now: now)?.first?.usedPercent == 40)
        #expect(ReadingChoice.best(signals: nil, usage: nil, now: now) == nil)
    }

    @Test func newerUsageReadingWinsOverFreshButOlderSignals() {
        let best = ReadingChoice.best(signals: reading(10, minutesAgo: 8), usage: reading(40, minutesAgo: 1), now: now)
        #expect(best?.first?.usedPercent == 40)
    }
}

@Suite struct PoolMemberTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func dated(_ limits: [UsageLimit], hoursAgo: Double) -> DatedLimits {
        DatedLimits(limits: limits, date: now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func staleReadingStillCountsAndPastResetsReadAsReset() throws {
        // Read three hours ago: the weekly window was 95% used and resets in an hour,
        // the 5-hour window was 60% used and reset an hour ago.
        let limits = [
            UsageLimit(kind: .session, usedPercent: 60, resetsAt: now.addingTimeInterval(-3600)),
            UsageLimit(kind: .weeklyAll, usedPercent: 95, resetsAt: now.addingTimeInterval(3600)),
        ]
        let max20 = PoolMember(plan: .paid(weight: PlanWeight(20)), signals: dated(limits, hoursAgo: 3), usage: nil)
        let team = PoolMember(plan: .paid(weight: PlanWeight(5)), signals: dated([UsageLimit(kind: .session, usedPercent: 0, resetsAt: nil)], hoursAgo: 0), usage: nil)
        let summary = try #require(Pool.summarize(PoolMember.poolInput([max20, team], now: now), at: now))
        #expect(abs(summary.weekly.freePercent - (20 * 5 + 5 * 100) / 25.0) < 0.01)
        #expect(abs(summary.session.freePercent - 100) < 0.01)
        #expect(!summary.isPartial)
    }

    @Test func onlyNeverReadOrUnweighedLoginsMakeThePoolPartial() throws {
        let read = PoolMember(plan: .paid(weight: PlanWeight(5)), signals: nil, usage: dated([UsageLimit(kind: .session, usedPercent: 50, resetsAt: nil)], hoursAgo: 30))
        let neverRead = PoolMember(plan: .paid(weight: PlanWeight(5)), signals: nil, usage: nil)
        let ended = PoolMember(plan: .inactive, signals: nil, usage: nil)
        #expect(Pool.summarize(PoolMember.poolInput([read, ended], now: now), at: now)?.isPartial == false)
        #expect(Pool.summarize(PoolMember.poolInput([read, neverRead], now: now), at: now)?.isPartial == true)
        #expect(PoolMember.poolInput([read, ended], now: now).count == 1)
    }
}

@Suite struct ProxyWeightTests {
    @Test func weightIsPlanSizeTimesFreePercent() {
        #expect(ProxyWeight.target(planWeight: 20, freePercent: 4) == 80)
        #expect(ProxyWeight.target(planWeight: 5, freePercent: 95) == 475)
    }

    @Test func exhaustedAccountKeepsAMinimalWeight() {
        #expect(ProxyWeight.target(planWeight: 20, freePercent: 0) == 1)
    }

    @Test func onlyChangesAboveTenPercentAreWritten() {
        #expect(!ProxyWeight.needsUpdate(current: 475, target: 520))
        #expect(!ProxyWeight.needsUpdate(current: 475, target: 430))
        #expect(ProxyWeight.needsUpdate(current: 475, target: 530))
        #expect(ProxyWeight.needsUpdate(current: 80, target: 60))
    }

    @Test func routingShareIsWeightOverTheSumOfWeights() {
        let shares = ProxyWeight.shares(["max": 80, "a": 475, "b": 465, "c": 390])
        #expect(abs((shares["max"] ?? 0) - 80.0 / 1410 * 100) < 0.001)
        #expect(abs(shares.values.reduce(0, +) - 100) < 0.001)
        #expect(ProxyWeight.shares(["x": 0]).isEmpty)
    }

    @Test func missingWeightIsAlwaysWritten() {
        #expect(ProxyWeight.needsUpdate(current: nil, target: 80))
        #expect(ProxyWeight.needsUpdate(current: 0, target: 80))
    }
}

/// Routing weighs what a login has left in the window that binds, both windows counted in its
/// provider's base-plan 5-hour windows.
@Suite struct BindingWindowTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
    private let max5x = PlanWeight(session: 5, weekly: 3.5)
    private let max20x = PlanWeight(session: 20, weekly: 7)
    private var claudeWeek: Double { PlanWeights.weekInWindows(provider: "claude") }

    private func limits(sessionFree: Double?, weeklyFree: Double?) -> [UsageLimit] {
        [
            sessionFree.map { UsageLimit(kind: .session, usedPercent: 100 - $0, resetsAt: now.addingTimeInterval(3600)) },
            weeklyFree.map { UsageLimit(kind: .weeklyAll, usedPercent: 100 - $0, resetsAt: now.addingTimeInterval(3 * 86400)) },
        ].compactMap { $0 }
    }

    private func target(_ weight: PlanWeight, sessionFree: Double?, weeklyFree: Double?, week: Double? = nil) -> (BindingWindow, Int) {
        let binding = BindingWindow.of(weight, limits: limits(sessionFree: sessionFree, weeklyFree: weeklyFree), weekInWindows: week ?? claudeWeek, at: now)
        return (binding, ProxyWeight.target(planWeight: binding.size, freePercent: binding.freePercent))
    }

    /// Max 5x's week holds about 11.8 of its own 5-hour windows (Botfarm, Feb 2026); at twice
    /// Max 5x's week, Max 20x's holds about 5.9 of its own, or 23.6 of Max 5x's (Botfarm: 6.6 and 26).
    @Test func aClaudeWeekHoldsTheMeasuredNumberOfFiveHourWindows() throws {
        let fiveX = try #require(PlanWeights.defaultWeight(provider: "claude", plan: "max_5x"))
        let twentyX = try #require(PlanWeights.defaultWeight(provider: "claude", plan: "max_20x"))
        #expect(abs(fiveX.weekly * claudeWeek / fiveX.session - 11.8) < 0.01)
        #expect(abs(twentyX.weekly * claudeWeek / twentyX.session - 5.9) < 0.01)
        #expect(abs(twentyX.weekly * claudeWeek / fiveX.session - 23.6) < 0.01)
    }

    @Test func theFiveHourWindowBindsWhileTheWeekHoldsMore() {
        let (binding, weight) = target(max5x, sessionFree: 95, weeklyFree: 50)
        #expect(binding.window == .session)
        #expect(weight == 475)
    }

    /// 60% of a Max 20x's 5-hour window is 12 Pro windows; 10% of its week is 11.8.
    @Test func theWeekBindsOnceItHoldsLessThanTheFiveHourWindow() {
        let (binding, weight) = target(max20x, sessionFree: 60, weeklyFree: 10)
        #expect(binding.window == .weekly)
        #expect(weight == 1180)
    }

    /// Half a Max 5x week is about six of its 5-hour windows: it can serve a whole fresh window.
    @Test func aHalfSpentWeekNoLongerHalvesTheWeight() {
        let (_, fresh) = target(max5x, sessionFree: 100, weeklyFree: 100)
        let (_, halfWeek) = target(max5x, sessionFree: 100, weeklyFree: 50)
        #expect(fresh == 500)
        #expect(halfWeek == 500)
    }

    @Test func aLoginWithOnlyOneWindowIsBoundByIt() {
        #expect(target(PlanWeight(20), sessionFree: nil, weeklyFree: 30, week: 1).0 == BindingWindow(window: .weekly, size: 20, freePercent: 30))
        #expect(target(max5x, sessionFree: 40, weeklyFree: nil).0 == BindingWindow(window: .session, size: 5, freePercent: 40))
        #expect(target(max5x, sessionFree: nil, weeklyFree: nil).0 == BindingWindow(window: .session, size: 5, freePercent: 100))
    }

    /// Codex publishes no weekly size in 5-hour windows: its week counts as one, so the lower share binds.
    @Test func withoutAMeasuredWeekTheLowerShareBinds() {
        #expect(PlanWeights.weekInWindows(provider: "codex") == 1)
        #expect(target(PlanWeight(1), sessionFree: 75, weeklyFree: 40, week: 1).1 == 40)
        #expect(target(PlanWeight(1), sessionFree: 30, weeklyFree: 40, week: 1).1 == 30)
    }

    @Test func modelScopedWeeklyLimitsNeverBind() {
        let scoped = [UsageLimit(kind: .session, usedPercent: 18, resetsAt: nil), UsageLimit(kind: .weeklyScoped, usedPercent: 100, resetsAt: nil)]
        #expect(BindingWindow.of(max5x, limits: scoped, weekInWindows: claudeWeek, at: now).window == .session)
    }
}

@Suite struct ResetUrgencyTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

    private func hours(_ value: Double) -> Date {
        now.addingTimeInterval(value * 3600)
    }

    @Test func farFromTheWeeklyResetThereIsNoUrgency() {
        #expect(ResetUrgency.factor(weeklyResetsAt: hours(100), now: now) == 1)
        #expect(ResetUrgency.factor(weeklyResetsAt: hours(48), now: now) == 1)
        #expect(ResetUrgency.factor(weeklyResetsAt: nil, now: now) == 1)
    }

    @Test func urgencyRisesSteadilyOverTheLastTwoDays() {
        #expect(abs(ResetUrgency.factor(weeklyResetsAt: hours(24), now: now) - 1.5) < 0.001)
        #expect(abs(ResetUrgency.factor(weeklyResetsAt: hours(12), now: now) - 1.75) < 0.001)
    }

    @Test func urgencyPeaksJustBeforeTheReset() {
        #expect(abs(ResetUrgency.factor(weeklyResetsAt: hours(0.01), now: now) - 2) < 0.001)
    }

    @Test func urgencyStaysWithinItsBounds() {
        for hoursLeft in stride(from: -10.0, through: 200, by: 0.5) {
            let factor = ResetUrgency.factor(weeklyResetsAt: hours(hoursLeft), now: now)
            #expect(factor >= 1 && factor <= 2, "\(hoursLeft) h → \(factor)")
        }
    }

    @Test func aResetThatAlreadyPassedStartsANewWeekWithoutUrgency() {
        #expect(ResetUrgency.factor(weeklyResetsAt: hours(-1), now: now) == 1)
    }

    @Test func urgencyScalesTheWeight() {
        #expect(ProxyWeight.target(planWeight: 5, freePercent: 40, urgency: 1.5) == 300)
        #expect(ProxyWeight.target(planWeight: 5, freePercent: 40) == 200)
    }

    @Test func urgencyCantLiftAnExhaustedAccount() {
        #expect(ProxyWeight.target(planWeight: 20, freePercent: 0, urgency: 2) == 1)
    }
}

@Suite struct ResetUrgencyExplanationTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

    private func login(_ provider: String, factor: Double, free: Double = 50) -> UrgentLogin {
        UrgentLogin(provider: provider, freePercent: free, factor: factor, weeklyResetsAt: now)
    }

    @Test func namesTheMostUrgentLoginsBoostAndTimeLeft() {
        let urgent = UrgentLogin(provider: "Codex", freePercent: 50, factor: 1.73, weeklyResetsAt: now.addingTimeInterval(13 * 3600))
        #expect(urgent.explanation(now: now, locale: Locale(identifier: "en_US")) == "Now ×1.7 for a Codex login whose week resets in 13h.")
    }

    @Test func picksTheStrongestBoostAmongLoginsWithRoomLeft() {
        let logins = [
            login("Claude", factor: 1.2), login("Claude", factor: 1),
            login("Codex", factor: 1.9, free: 0), login("Codex", factor: 1.8), login("Codex", factor: 1),
        ]
        #expect(UrgentLogin.strongest(logins)?.factor == 1.8)
    }

    @Test func aBoostThatWouldReadAsTimesOneIsNotShown() {
        #expect(UrgentLogin.strongest([login("Claude", factor: 1.04), login("Claude", factor: 1)]) == nil)
    }

    @Test func aProviderWithOneLoginHasNothingToSteer() {
        #expect(UrgentLogin.strongest([login("Codex", factor: 1.8)]) == nil)
    }
}

@Suite struct WeeklyResetChoiceTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

    @Test func onlyTheWholeWeeklyWindowDrivesUrgency() {
        let weekly = now.addingTimeInterval(20 * 3600)
        let limits = [
            UsageLimit(kind: .session, usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
            UsageLimit(kind: .weeklyScoped, usedPercent: 10, resetsAt: now.addingTimeInterval(2 * 3600)),
            UsageLimit(kind: .weeklyAll, usedPercent: 10, resetsAt: weekly),
        ]
        #expect(ResetUrgency.weeklyReset(in: limits) == weekly)
        #expect(ResetUrgency.weeklyReset(in: Array(limits.prefix(2))) == nil)
    }
}
