import Foundation
import Testing
@testable import EbbCore

private let t0 = Date(timeIntervalSince1970: 1_793_040_000)

/// Deterministic, so a failing case can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite(.hangLimit) struct PoolNumbersStayOnTheGaugeTests {
    private func randomLimit(_ kind: UsageLimit.Kind, using generator: inout SeededGenerator) -> UsageLimit? {
        guard Int.random(in: 0..<5, using: &generator) != 0 else { return nil }
        let used = [-40.0, -0.01, 0, 33.3, 99.99, 100, 101, 180, 10_000].randomElement(using: &generator)!
        let reset = [nil, t0 - 3600, t0 + 60, t0 + 4 * 3600, t0 + 5 * 86_400].randomElement(using: &generator)!
        return UsageLimit(kind: kind, usedPercent: used, resetsAt: reset)
    }

    @Test func freeShareIsBetweenZeroAndAHundredWhateverTheReadings() throws {
        var generator = SeededGenerator(state: 7)
        for _ in 0..<2_000 {
            let accounts = (0..<Int.random(in: 1...6, using: &generator)).map { _ -> AccountUsage? in
                guard Int.random(in: 0..<6, using: &generator) != 0 else { return nil }
                let limits = [randomLimit(.session, using: &generator), randomLimit(.weeklyAll, using: &generator)].compactMap { $0 }
                return AccountUsage(weight: PlanWeight([0.5, 1, 5, 20].randomElement(using: &generator)!), limits: limits, readAt: t0)
            }
            guard let summary = Pool.summarize(accounts, at: t0) else { continue }
            for window in [summary.session, summary.weekly] {
                #expect((0...100).contains(window.freePercent), "\(window.freePercent) from \(accounts)")
                #expect(window.resets.allSatisfy { $0.gain >= 0 })
            }
            let pool = MenuBarPool(summary: summary, shortWindow: .fiveHours, accounts: [], lastReadAt: t0, now: t0)
            #expect((0...100).contains(pool.session.percent) && (0...100).contains(pool.weekly.percent))
            #expect(pool.session.percent == Int(summary.session.freePercent.rounded()))
        }
    }

    @Test func utilizationAboveOneFromTheHeadersStillReadsAsEmpty() throws {
        let limits = try #require(ClaudeProvider().limits(fromSignals: [
            "Anthropic-Ratelimit-Unified-5h-Utilization": "1.17",
            "Anthropic-Ratelimit-Unified-7d-Utilization": "-0.2",
        ]))
        let summary = try #require(Pool.summarize([AccountUsage(weight: PlanWeight(5), limits: limits, readAt: t0)], at: t0))
        #expect(summary.session.freePercent == 0)
        #expect(summary.weekly.freePercent == 100)
    }
}

@Suite(.hangLimit) struct StaleCooldownTests {
    private func listing(retryAfterDays: Double) throws -> ProxyAuthFile {
        let retry = (t0 + retryAfterDays * 86_400).formatted(.iso8601)
        let observed = t0.formatted(.iso8601)
        let reset = Int(t0.timeIntervalSince1970) + 3600
        let json = #"{"files":[{"name":"claude-1-held@example.com.json","provider":"claude","type":"claude","email":"held@example.com","disabled":false,"unavailable":true,"status":"error","status_message":"quota exhausted","next_retry_after":"\#(retry)","weight":100,"quota":{"observed_at":"\#(observed)","signals":{"Anthropic-Ratelimit-Unified-5h-Utilization":"0.10","Anthropic-Ratelimit-Unified-5h-Reset":"\#(reset)","Anthropic-Ratelimit-Unified-7d-Utilization":"0.20","Anthropic-Ratelimit-Unified-7d-Reset":"\#(reset + 100000)"}}}]}"#
        return try #require(ProxyAuthFile.parseList(Data(json.utf8))?.first)
    }

    @Test func anAccountHeldForDaysStillCountsItsFreeQuota() throws {
        let file = try listing(retryAfterDays: 18)
        #expect(file.health.state == .coolingDown(until: t0 + 18 * 86_400))
        let member = PoolMember(plan: .paid(weight: PlanWeight(5)), signals: file.quota, usage: nil)
        let summary = try #require(Pool.summarize(PoolMember.poolInput([member], now: t0), at: t0))
        #expect(summary.session.freePercent == 90)
        #expect(summary.weekly.freePercent == 80)
        #expect(!summary.isPartial)
    }

    /// The proxy's cooldown isn't an input to retirement at all; only the usage call's outcome is.
    @Test func aRateLimitOrFailureNeverRetiresTheAccount() {
        for failures in [0, 1, 5] {
            #expect(Retirement.action(after: .failed, isDisabled: false, isRetiredByUs: false, inactiveStreak: failures) == .keep)
            #expect(Retirement.action(after: .rateLimited(retryAfter: 18 * 86_400), isDisabled: false, isRetiredByUs: false, inactiveStreak: failures) == .keep)
        }
    }

    @Test func theHeldAccountIsFlaggedWhenAFreshReadingShowsQuota() throws {
        let file = try listing(retryAfterDays: 18)
        let usage = DatedLimits(limits: [UsageLimit(kind: .session, usedPercent: 10, resetsAt: t0 + 3600)], date: t0 + 60)
        #expect(StuckCooldown.isStuck(health: file.health, usage: usage, signalsObservedAt: file.signalsObservedAt, now: t0 + 120))
    }
}

@Suite(.hangLimit) struct RefreshTrafficTests {
    /// What the store does on each trigger: one job at most, the account tried longest ago, never closer than `minimumSpacing`.
    /// Triggers come every 20 s, faster than the spacing allows, so the spacing rule has to hold them back.
    @Test func fourIdleAccountsAreReadAtMostOncePerMinuteAndOncePerFiveMinutesEach() {
        var states = Dictionary(uniqueKeysWithValues: (1...4).map { ("a\($0)", FetchState()) })
        var lastRequest: Date?
        var requests: [(account: String, at: Date)] = []
        for tick in 0..<180 {
            let now = t0 + Double(tick) * 20
            guard RefreshPlan.isSlotFree(lastRequest: lastRequest, now: now),
                  let account = RefreshPlan.nextAccount(in: states, minimumAge: RefreshPlan.period - 30, now: now)
            else { continue }
            lastRequest = now
            states[account]?.lastAttempt = now
            requests.append((account, now))
        }
        let times = requests.map(\.at)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= RefreshPlan.minimumSpacing })
        #expect(requests.count <= 4 * (3600 / Int(RefreshPlan.period - 30) + 1))
        for account in states.keys {
            let times = requests.filter { $0.account == account }.map(\.at)
            #expect(times.count >= 10, "\(account) was read \(times.count) times in an hour")
            #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= RefreshPlan.period - 30 })
        }
    }

    @Test func aRateLimitedAccountIsLeftAloneUntilItsBackoffEnds() {
        var states = ["a1": FetchState(), "a2": FetchState()]
        let failedAt = t0
        states["a1"] = FetchState(lastAttempt: failedAt, retryNotBefore: failedAt + Backoff.delay(afterFailures: 1, retryAfter: nil), failures: 1, lastOutcome: .rateLimited)
        states["a2"]?.lastAttempt = failedAt + 1
        for seconds in stride(from: 60.0, to: 119, by: 30) {
            #expect(RefreshPlan.nextAccount(in: states, minimumAge: 0, now: failedAt + seconds) == "a2")
        }
        #expect(RefreshPlan.nextAccount(in: states, minimumAge: 0, now: failedAt + 121) == "a1")
    }

    /// The last request's time is saved, so a clock set back an hour would otherwise hold every read for that hour.
    @Test func aClockSetBackFreesTheSlotInsteadOfWaitingItOut() {
        #expect(RefreshPlan.isSlotFree(lastRequest: t0 + 3600, now: t0))
        #expect(!RefreshPlan.isSlotFree(lastRequest: t0 - 30, now: t0))
    }

    @Test func eachFailureInARowDoublesTheWaitUpToThirtyMinutes() {
        let waits = (1...8).map { Backoff.delay(afterFailures: $0, retryAfter: nil) }
        #expect(waits == [120, 240, 480, 960, 1_800, 1_800, 1_800, 1_800])
    }
}
