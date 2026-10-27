import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func at(_ minutes: Double) -> Date {
    now.addingTimeInterval(minutes * 60)
}

private func session(_ used: Double, resetsIn minutes: Double = 120) -> UsageLimit {
    UsageLimit(kind: .session, usedPercent: used, resetsAt: at(minutes))
}

private func weekly(_ used: Double, resetsIn minutes: Double = 3 * 24 * 60) -> UsageLimit {
    UsageLimit(kind: .weeklyAll, usedPercent: used, resetsAt: at(minutes))
}

private func fixture(_ name: String) throws -> [UsageLimit] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try UsageLimit.decodeList(from: Data(contentsOf: url))
}

private func expectClose(_ value: Double?, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value.map { abs($0 - expected) < 0.01 } == true, "\(String(describing: value)) ≠ \(expected)", sourceLocation: sourceLocation)
}

@Suite struct DecodingTests {
    @Test func cachedReadingsDecodeWithMicrosecondTimestamps() throws {
        let limits = try fixture("max-weekly-critical")
        #expect(limits.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
        #expect(limits[1].usedPercent == 95)
        let sessionReset = try #require(limits[0].resetsAt)
        #expect(Int(sessionReset.timeIntervalSince1970) == Int(UsageLimit.parseTimestamp("2026-10-26T23:09:59+00:00")!.timeIntervalSince1970))
    }

    @Test func encodedLimitsDecodeBackUnchanged() throws {
        let limits = [
            UsageLimit(kind: .session, usedPercent: 11, resetsAt: Date(timeIntervalSince1970: 1_793_056_200)),
            UsageLimit(kind: .weeklyAll, usedPercent: 95.5, resetsAt: Date(timeIntervalSince1970: 1_793_149_200)),
        ]
        #expect(try UsageLimit.decodeList(from: UsageLimit.encodeList(limits)) == limits)
    }

    @Test func timestampsWithoutFractionDecode() throws {
        let limits = try fixture("team-session-5-b")
        #expect(limits[1].resetsAt == UsageLimit.parseTimestamp("2026-11-01T06:00:00.000+00:00"))
        #expect(limits[1].resetsAt != nil)
    }
}

@Suite struct AccountFreeTests {
    @Test func accountFreeIsBoundByItsTightestWindow() {
        expectClose(Pool.effectiveFree([session(9), weekly(95)], at: now), 5)
        expectClose(Pool.effectiveFree([session(60), weekly(20)], at: now), 40)
    }

    @Test func modelScopedWeeklyLimitsDoNotBind() {
        let scoped = UsageLimit(kind: .weeklyScoped, usedPercent: 100, resetsAt: at(600))
        expectClose(Pool.effectiveFree([session(18), scoped], at: now), 82)
    }
}

@Suite struct WindowFreeTests {
    @Test func sessionFreeIsWeightedByPlanSizeAndIgnoresTheWeeklyCap() {
        let max20 = AccountUsage(weight: PlanWeight(20), limits: [session(50), weekly(95)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(0)])
        expectClose(Pool.summarize([max20, team], at: now)?.session.freePercent, 60)
    }

    @Test func weeklyFreeCountsAccountsWithoutAWeeklyCapAsFullyFree() {
        let max20 = AccountUsage(weight: PlanWeight(20), limits: [session(0), weekly(80)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(90)])
        expectClose(Pool.summarize([max20, team], at: now)?.weekly.freePercent, (20 * 20 + 5 * 100) / 25.0)
    }

    @Test func windowsPastTheirResetCountAsUnused() {
        let stale = AccountUsage(weight: PlanWeight(5), limits: [session(80, resetsIn: -1)])
        expectClose(Pool.summarize([stale], at: now)?.session.freePercent, 100)
    }

    @Test func todaysCachedPoolMatchesHandMath() throws {
        let summary = try #require(Pool.summarize(try todaysAccounts(), at: now))
        // (20·91 + 5·82 + 5·95 + 5·95) / 35
        expectClose(summary.session.freePercent, 3180.0 / 35)
        // (20·5 + 5·100 · 3) / 35
        expectClose(summary.weekly.freePercent, 1600.0 / 35)
    }
}

private func todaysAccounts() throws -> [AccountUsage] {
    [
        AccountUsage(weight: PlanWeight(20), limits: try fixture("max-weekly-critical")),
        AccountUsage(weight: PlanWeight(5), limits: try fixture("team-session-18")),
        AccountUsage(weight: PlanWeight(5), limits: try fixture("team-session-5")),
        AccountUsage(weight: PlanWeight(5), limits: try fixture("team-session-5-b")),
    ]
}

@Suite struct UnreadableAccountTests {
    @Test func unreadableAccountsLeaveTheTotalsAndMarkThemPartial() throws {
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(50)])
        let summary = try #require(Pool.summarize([team, nil], at: now))
        expectClose(summary.session.freePercent, 50)
        #expect(summary.isPartial)
    }

    @Test func fullyReadPoolIsNotPartial() {
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(50)])
        #expect(Pool.summarize([team, team], at: now)?.isPartial == false)
    }

    @Test func poolWithNoReadingsHasNoSummary() {
        #expect(Pool.summarize([nil, nil], at: now) == nil)
    }
}

@Suite struct WindowResetTests {
    @Test func sessionResetGivesBackWhatTheAccountUsedEvenUnderAnExhaustedWeek() throws {
        // Per-window math: the 5-hour bucket refills regardless of the weekly one.
        let max20 = AccountUsage(weight: PlanWeight(20), limits: [session(9, resetsIn: 30), weekly(95)])
        let team = AccountUsage(weight: PlanWeight(15), limits: [session(0)])
        let resets = try #require(Pool.summarize([max20, team], at: now)).session.resets
        #expect(resets.map(\.date) == [at(30)])
        expectClose(resets.first?.gain, 20 * 9 / 35.0)
    }

    @Test func todaysFiveHourLineIncludesTheMaxAccountsSessionReset() throws {
        let summary = try #require(Pool.summarize(try todaysAccounts(), at: now))
        let line = try #require(GainLine.session(summary.session.resets))
        let maxSessionReset = UsageLimit.parseTimestamp("2026-10-26T23:09:59.828140+00:00")!
        // Raw gains 2.57 + 5.14 + 0.71 + 0.71 = 9.14, shown as +9% split 2 + 5 + 1 + 1.
        #expect(line.points == 9)
        #expect(line.items.map(\.points) == [2, 5, 1, 1])
        #expect(line.items.contains(GainItem(date: maxSessionReset, points: 5)))
    }

    @Test func sessionResetsBeyondFiveHoursAreLeftOut() throws {
        let soon = AccountUsage(weight: PlanWeight(5), limits: [session(40, resetsIn: 60)])
        let odd = AccountUsage(weight: PlanWeight(5), limits: [session(40, resetsIn: 6 * 60)])
        let resets = try #require(Pool.summarize([soon, odd], at: now)).session.resets
        #expect(resets.map(\.date) == [at(60)])
    }

    @Test func weeklyResetGivesBackTheWeeklyShareOnly() throws {
        let summary = try #require(Pool.summarize(try todaysAccounts(), at: now))
        let weekReset = UsageLimit.parseTimestamp("2026-10-28T01:00:00.828160+00:00")!
        #expect(summary.weekly.resets.map(\.date) == [weekReset])
        expectClose(summary.weekly.resets.first?.gain, 20 * 95 / 35.0)
    }

    @Test func resetsWithinFiveMinutesMergeIntoOneEventAtTheLaterTime() throws {
        let first = AccountUsage(weight: PlanWeight(5), limits: [session(40, resetsIn: 10)])
        let second = AccountUsage(weight: PlanWeight(5), limits: [session(20, resetsIn: 14)])
        let resets = try #require(Pool.summarize([first, second], at: now)).session.resets
        #expect(resets.map(\.date) == [at(14)])
        expectClose(resets.first?.gain, 30)
    }

    @Test func resetsMoreThanFiveMinutesApartStaySeparate() throws {
        let first = AccountUsage(weight: PlanWeight(5), limits: [session(40, resetsIn: 10)])
        let second = AccountUsage(weight: PlanWeight(5), limits: [session(20, resetsIn: 16)])
        let resets = try #require(Pool.summarize([first, second], at: now)).session.resets
        #expect(resets.map(\.date) == [at(10), at(16)])
    }

    @Test func passedOrUnusedResetsAreNotUpcoming() throws {
        let passed = AccountUsage(weight: PlanWeight(5), limits: [session(50, resetsIn: -5)])
        let unused = AccountUsage(weight: PlanWeight(5), limits: [session(0, resetsIn: 30)])
        #expect(Pool.summarize([passed, unused], at: now)?.session.resets == [])
    }
}

@Suite struct GainLineTests {
    private func resets(_ gains: [Double]) -> [Restoration] {
        gains.enumerated().map { Restoration(date: at(Double($0.offset + 1) * 20), gain: $0.element) }
    }

    @Test func sessionLineSumsEveryResetInTheWindow() throws {
        let line = try #require(GainLine.session(resets([2.6, 1.3, 1.4])))
        #expect(line.points == 5)
        #expect(line.lastDate == at(60))
    }

    @Test func breakdownAddsUpToTheLineByLargestRemainder() throws {
        // Rounded one by one these would read 3 + 1 + 1 + 1 = 6 under a line of 5.
        let line = try #require(GainLine.session(resets([2.6, 1.3, 0.6, 0.6])))
        #expect(line.points == 5)
        #expect(line.items.map(\.points) == [3, 1, 1])
        #expect(line.items.reduce(0) { $0 + $1.points } == line.points)
    }

    @Test func breakdownSumsMatchTheLineForManyMixes() throws {
        let mixes: [[Double]] = [[0.4, 0.4, 0.4], [5.5, 0.5], [1.49, 1.49, 1.49, 1.49], [33.3, 33.3, 33.4], [0.2, 0.9]]
        for mix in mixes {
            let line = try #require(GainLine.session(resets(mix)))
            #expect(line.items.reduce(0) { $0 + $1.points } == line.points, "\(mix)")
            #expect(line.points == Int(mix.reduce(0, +).rounded()), "\(mix)")
        }
    }

    @Test func sessionLineIsHiddenUnderOnePoint() {
        #expect(GainLine.session(resets([0.2, 0.2])) == nil)
        #expect(GainLine.session([]) == nil)
    }

    @Test func weeklyLineIsTheNextResetWorthAPoint() throws {
        let line = try #require(GainLine.weekly(resets([0.3, 54.3, 12])))
        #expect(line.points == 54)
        #expect(line.items == [GainItem(date: at(40), points: 54)])
        #expect(line.later == [GainItem(date: at(60), points: 12)])
    }

    @Test func weeklyLineIsHiddenWithoutAWeeklyReset() {
        #expect(GainLine.weekly([]) == nil)
        #expect(GainLine.weekly(resets([0.4])) == nil)
    }
}

@Suite struct BackoffTests {
    @Test func backoffDoublesFromTwoMinutesUpToThirty() {
        #expect((1...6).map { Backoff.delay(afterFailures: $0, retryAfter: nil) } == [120, 240, 480, 960, 1800, 1800])
    }

    @Test func retryAfterHeaderWins() {
        #expect(Backoff.delay(afterFailures: 5, retryAfter: 42) == 42)
        #expect(Backoff.retryAfter("90", now: now) == 90)
        #expect(Backoff.retryAfter("Mon, 26 Oct 2026 19:44:00 GMT", now: now) == 600)
        #expect(Backoff.retryAfter(nil, now: now) == nil)
    }
}

@Suite struct RefreshPlanTests {
    @Test func picksTheAccountTriedLongestAgo() {
        let states = [
            "a": FetchState(lastAttempt: at(-2)),
            "b": FetchState(lastAttempt: at(-6)),
            "c": FetchState(lastAttempt: at(-4)),
        ]
        #expect(RefreshPlan.nextAccount(in: states, minimumAge: 0, now: now) == "b")
    }

    @Test func skipsAccountsBackingOffOrReadRecently() {
        let states = [
            "a": FetchState(lastAttempt: at(-10), retryNotBefore: at(5)),
            "b": FetchState(lastAttempt: at(-1)),
        ]
        #expect(RefreshPlan.nextAccount(in: states, minimumAge: 120, now: now) == nil)
        #expect(RefreshPlan.nextAccount(in: states, minimumAge: 30, now: now) == "b")
    }

    /// Two triggers can pick the same login; the one that waited for the slot must not read it again.
    @Test func aLoginReadWhileTheJobWaitedForItsSlotIsSkipped() {
        let chosenAt = now
        #expect(!RefreshPlan.isStillDue(FetchState(lastAttempt: chosenAt + 0.1), chosenAt: chosenAt))
        #expect(RefreshPlan.isStillDue(FetchState(lastAttempt: chosenAt - RefreshPlan.period), chosenAt: chosenAt))
        #expect(RefreshPlan.isStillDue(nil, chosenAt: chosenAt))
    }
}

@Suite struct HonestPoolTests {
    @Test func anAccountAtItsWeeklyLimitCountsNothingInTheFiveHourPool() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(10), weekly(99.5)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(40)])
        let summary = try #require(Pool.summarize([spent, team], at: now))

        expectClose(summary.session.freePercent, 5 * 60 / 25.0)
        #expect(summary.weeklyLimitedAccounts == 1)
        #expect(summary.readAccounts == 2)
    }

    @Test func aPartlyUsedWeekStillCountsInFull() throws {
        let busy = AccountUsage(weight: PlanWeight(20), limits: [session(10), weekly(98)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(40)])
        let summary = try #require(Pool.summarize([busy, team], at: now))

        expectClose(summary.session.freePercent, (20 * 90 + 5 * 60) / 25.0)
        #expect(summary.weeklyLimitedAccounts == 0)
    }

    @Test func aSpentWeekKeepsItsFiveHourResetOutOfTheLine() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(30, resetsIn: 30), UsageLimit(kind: .weeklyAll, usedPercent: 100, resetsAt: at(3 * 24 * 60))])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(40, resetsIn: 60)])
        let resets = try #require(Pool.summarize([spent, team], at: now)).session.resets

        #expect(resets.map(\.date) == [at(60)])
    }

    @Test func theWeeklyResetBringsTheFiveHourCapacityBack() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(30, resetsIn: 30), UsageLimit(kind: .weeklyAll, usedPercent: 100, resetsAt: at(120))])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(0)])
        let resets = try #require(Pool.summarize([spent, team], at: now)).session.resets

        #expect(resets.map(\.date) == [at(120)])
        expectClose(resets.first?.gain, 20 * 100 / 25.0)
    }

    /// Lucas's pool: three Max 5x at 55% free and a Max 20x whose week is spent reads 25% free,
    /// and 57% of it is locked until that week resets.
    @Test func aSpentWeeksShareOfTheFiveHourPoolIsLockedUntilItResets() throws {
        let max5x = AccountUsage(weight: PlanWeight(session: 5, weekly: 3.5), limits: [session(45), weekly(40)])
        let spent = AccountUsage(weight: PlanWeight(session: 20, weekly: 7), limits: [session(0), weekly(100, resetsIn: 26 * 60)])
        let summary = try #require(Pool.summarize([max5x, max5x, max5x, spent], at: now))

        expectClose(summary.session.freePercent, 15 * 55 / 35.0)
        expectClose(summary.session.lockedPercent, 20 * 100 / 35.0)
        #expect(summary.session.unlocksAt == at(26 * 60))
        #expect(summary.weekly.lockedPercent == 0)
        #expect(summary.weekly.unlocksAt == nil)
    }

    @Test func theEarliestSpentWeekSetsTheUnlock() throws {
        let later = AccountUsage(weight: PlanWeight(5), limits: [session(0), weekly(99.5, resetsIn: 3 * 24 * 60)])
        let sooner = AccountUsage(weight: PlanWeight(5), limits: [session(0), weekly(100, resetsIn: 24 * 60)])
        let undated = AccountUsage(weight: PlanWeight(5), limits: [session(0), UsageLimit(kind: .weeklyAll, usedPercent: 100, resetsAt: nil)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(40), weekly(98)])
        let summary = try #require(Pool.summarize([later, sooner, undated, team], at: now))

        expectClose(summary.session.lockedPercent, 75)
        #expect(summary.session.unlocksAt == at(24 * 60))
    }

    @Test func aPoolWithoutASpentWeekHasNothingLocked() throws {
        let summary = try #require(Pool.summarize([AccountUsage(weight: PlanWeight(5), limits: [session(90), weekly(98)])], at: now))

        #expect(summary.session.lockedPercent == 0)
        #expect(summary.session.unlocksAt == nil)
    }

    @Test func unreadAccountsAreCountedForTheHoverCard() throws {
        let read = AccountUsage(weight: PlanWeight(5), limits: [session(10)], readAt: at(-3))
        let older = AccountUsage(weight: PlanWeight(5), limits: [session(10)], readAt: at(-7))
        let summary = try #require(Pool.summarize([read, older, nil], at: now))

        #expect(summary.unreadAccounts == 1)
        #expect(summary.oldestReadingAt == at(-7))
    }
}

@Suite struct PoolNotesTests {
    private func summary(read: Int, unread: Int = 0, weeklyLimited: Int = 0, oldest: Date? = nil) -> PoolSummary {
        PoolSummary(
            session: WindowSummary(freePercent: 50, resets: []), weekly: WindowSummary(freePercent: 50, resets: []),
            isPartial: unread > 0, readAccounts: read, unreadAccounts: unread, weeklyLimitedAccounts: weeklyLimited, oldestReadingAt: oldest
        )
    }

    @Test func theFiveHourCardSaysHowManyAccountsAreAtTheirWeeklyLimit() {
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 1), window: .session, now: now) == ["1 of 4 accounts at their weekly limit"])
        #expect(PoolNotes.lines(summary(read: 1, weeklyLimited: 1), window: .session, now: now) == ["Its only account is at its weekly limit"])
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 1), window: .weekly, now: now).isEmpty)
    }

    @Test func aLockedShareReadsWithItsUnlockInTheLocalesClock() {
        let utc = TimeZone(identifier: "UTC")!
        let tuesday = UsageLimit.parseTimestamp("2026-10-27T22:00:00+00:00")!
        let window = WindowSummary(freePercent: 23.6, resets: [], lockedPercent: 57.1, unlocksAt: tuesday)
        #expect(PoolNotes.locked(window, timeZone: utc, locale: Locale(identifier: "en_US")) == "57% locked until Tue 10:00\u{202F}PM")
        #expect(PoolNotes.locked(window, timeZone: utc, locale: Locale(identifier: "pt_BR")) == "57% bloqueado até ter. 22:00")
        #expect(PoolNotes.locked(WindowSummary(freePercent: 50, resets: [], lockedPercent: 30), timeZone: utc, locale: Locale(identifier: "en_US")) == "30% locked until the weekly reset")
    }

    @Test func aLockedShareUnderFivePercentStaysOffTheMeter() {
        let window = WindowSummary(freePercent: 50, resets: [], lockedPercent: 4.9, unlocksAt: at(60))
        #expect(PoolNotes.locked(window) == nil)
        #expect(PoolNotes.locked(WindowSummary(freePercent: 50, resets: [], lockedPercent: 5, unlocksAt: at(60))) != nil)
        #expect(PoolNotes.locked(WindowSummary(freePercent: 50, resets: [])) == nil)
    }

    @Test func bothCardsSayHowOldTheNumbersAreAndWhatIsLeftOut() {
        let lines = PoolNotes.lines(summary(read: 3, unread: 2, oldest: at(-3)), window: .weekly, now: now)
        #expect(lines == ["As of 3 min ago", "2 accounts can't be read right now"])
        #expect(PoolNotes.lines(summary(read: 3, unread: 1, oldest: at(-0.2)), window: .session, now: now) == ["As of 12 s ago", "1 account can't be read right now"])
    }
}

@Suite struct SpentWeekResetTests {
    @Test func aFiveHourResetAfterTheWeeklyOneStillComesBack() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(30, resetsIn: 120), weekly(100, resetsIn: 60)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(0)])
        let resets = try #require(Pool.summarize([spent, team], at: now)).session.resets

        #expect(resets.map(\.date) == [at(60), at(120)])
        expectClose(resets.first?.gain, 20 * 70 / 25.0)
        expectClose(resets.last?.gain, 20 * 30 / 25.0)
    }

    @Test func aWeeklyResetThatBringsNothingBackIsNotListed() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(100, resetsIn: 180), weekly(100, resetsIn: 60)])
        let team = AccountUsage(weight: PlanWeight(5), limits: [session(0)])
        let resets = try #require(Pool.summarize([spent, team], at: now)).session.resets

        #expect(resets.map(\.date) == [at(180)])
        expectClose(resets.first?.gain, 20 * 100 / 25.0)
    }
}

/// A Max 20x weighs four Max 5x's in the 5-hour pool but only two in the weekly one.
@Suite struct PerWindowWeightTests {
    private let max20 = PlanWeight(session: 20, weekly: 7)
    private let max5 = PlanWeight(session: 5, weekly: 3.5)

    @Test func eachMeterWeighsAccountsByItsOwnWindowsPlanWeight() throws {
        let summary = try #require(Pool.summarize([
            AccountUsage(weight: max20, limits: [session(50), weekly(80)]),
            AccountUsage(weight: max5, limits: [session(0), weekly(20)]),
        ], at: now))
        expectClose(summary.session.freePercent, (20 * 50 + 5 * 100) / 25.0)
        expectClose(summary.weekly.freePercent, (7 * 20 + 3.5 * 80) / 10.5)
        #expect(summary.totalWeight == PlanWeight(session: 25, weekly: 10.5))
    }

    @Test func weeklyResetsAndTheUncappedShareAreInWeeklyWeights() throws {
        let summary = try #require(Pool.summarize([
            AccountUsage(weight: max20, limits: [session(0), weekly(60, resetsIn: 600)]),
            AccountUsage(weight: max5, limits: [session(0)]),
        ], at: now))
        expectClose(summary.weekly.resets.first?.gain, 7 * 60 / 10.5)
        expectClose(summary.weekly.uncappedPercent, 3.5 * 100 / 10.5)
    }

    @Test func aSpentWeekCountsNothingInTheFiveHourPoolInFiveHourWeights() throws {
        let summary = try #require(Pool.summarize([
            AccountUsage(weight: max20, limits: [session(30, resetsIn: 30), UsageLimit(kind: .weeklyAll, usedPercent: 100, resetsAt: at(120))]),
            AccountUsage(weight: max5, limits: [session(40, resetsIn: 60)]),
        ], at: now))
        expectClose(summary.session.freePercent, 5 * 60 / 25.0)
        #expect(summary.session.resets.map(\.date) == [at(60), at(120)])
        expectClose(summary.session.resets.first?.gain, 5 * 40 / 25.0)
        expectClose(summary.session.resets.last?.gain, 20 * 100 / 25.0)
    }

    @Test func theWeeklyBudgetPacesTheWeeklyMetersShare() throws {
        let summary = try #require(Pool.summarize([
            AccountUsage(weight: max20, limits: [session(0), weekly(80)]),
            AccountUsage(weight: max5, limits: [session(0), weekly(20)]),
        ], at: now))
        let budget = try #require(summary.weeklyBudget)
        expectClose(budget.freePercent, (7 * 20 + 3.5 * 80) / 10.5)
    }
}

@Suite struct PoolNotesInlineTests {
    @Test func aPoolEmptiedByWeeklyLimitsSaysWhyUnderTheMeter() throws {
        let spent = AccountUsage(weight: PlanWeight(20), limits: [session(0), weekly(100)])
        let summary = try #require(Pool.summarize([spent, AccountUsage(weight: PlanWeight(5), limits: [session(100, resetsIn: 600)])], at: now))
        #expect(PoolNotes.inline(summary) == "1 of 2 at weekly limit")
    }
}
