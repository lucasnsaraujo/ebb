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

    @Test func accountWithoutSignalsHasNoQuotaAndOtherProvidersAreSkipped() throws {
        let files = try listing()
        #expect(files.map(\.name) == ["claude-4c515511-max@example.com.json", "claude-f11cea8c-team@example.com.json", "claude-0000-idle@example.com.json"])
        #expect(files[2].quota == nil)
        #expect(files[2].isDisabled)
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
        let max20 = PoolMember(plan: .paid(weight: 20), signals: dated(limits, hoursAgo: 3), usage: nil)
        let team = PoolMember(plan: .paid(weight: 5), signals: dated([UsageLimit(kind: .session, usedPercent: 0, resetsAt: nil)], hoursAgo: 0), usage: nil)
        let summary = try #require(Pool.summarize(PoolMember.poolInput([max20, team], now: now), at: now))
        #expect(abs(summary.weekly.freePercent - (20 * 5 + 5 * 100) / 25.0) < 0.01)
        #expect(abs(summary.session.freePercent - 100) < 0.01)
        #expect(!summary.isPartial)
    }

    @Test func onlyNeverReadOrUnweighedLoginsMakeThePoolPartial() throws {
        let read = PoolMember(plan: .paid(weight: 5), signals: nil, usage: dated([UsageLimit(kind: .session, usedPercent: 50, resetsAt: nil)], hoursAgo: 30))
        let neverRead = PoolMember(plan: .paid(weight: 5), signals: nil, usage: nil)
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
