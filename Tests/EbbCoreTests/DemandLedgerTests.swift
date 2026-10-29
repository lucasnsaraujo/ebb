import Foundation
import Testing
@testable import EbbCore

let ledgerStart = Date(timeIntervalSince1970: 1_793_040_000)

/// Drives a ledger the way the store does: a poll every 30 s, each account's reading recorded.
struct LedgerRun {
    var ledger = DemandLedger()
    var now = ledgerStart
    var weights: [String: Double]
    var used: [String: Double] = [:]
    var resets: [String: Date] = [:]
    var kind = DemandLedger.Kind.session
    var window: TimeInterval = 5 * 60 * 60
    let pool = "claude"

    init(weights: [String: Double], kind: DemandLedger.Kind = .session) {
        self.weights = weights
        self.kind = kind
        window = kind == .session ? 5 * 60 * 60 : 7 * 24 * 60 * 60
        for account in weights.keys {
            used[account] = 0
            resets[account] = ledgerStart + window - 60
        }
    }

    var totals: (units: Double, unwatched: Double, events: Int) {
        ledger.totals(pool: pool, kind: kind)
    }

    /// One poll: the heartbeat, then every account's current reading.
    mutating func poll() {
        ledger.heartbeat(at: now)
        for account in weights.keys.sorted() {
            record(account)
        }
    }

    mutating func record(_ account: String, at date: Date? = nil) {
        let readAt = date ?? now
        let limit = UsageLimit(kind: kind == .session ? .session : .weeklyAll, usedPercent: used[account] ?? 0, resetsAt: resets[account])
        ledger.record(limit, readAt: readAt, pool: pool, kind: kind, account: account, weight: weights[account] ?? 0, window: window)
    }

    /// Each account's use grows by its rate in points per hour, polled every 30 s.
    mutating func burn(_ rates: [String: Double], minutes: Double) {
        for _ in 0..<Int(minutes * 2) {
            now += 30
            for (account, rate) in rates {
                used[account, default: 0] += rate / 120
            }
            poll()
        }
    }

    /// Polls with nothing changing.
    mutating func idle(minutes: Double) {
        burn([:], minutes: minutes)
    }

    /// Time passes with no polls: asleep, quit or hidden.
    mutating func away(minutes: Double) {
        now += minutes * 60
    }
}

@Suite(.hangLimit) struct DemandLedgerTests {
    /// Session demand in 5-hour weights, weekly demand in weekly weights: a Max 20x using 10
    /// points of its 5-hour window and 2 of its week adds 20 × 10 and 7 × 2.
    @Test func eachWindowsDemandIsWeighedInItsOwnPlanWeight() {
        var ledger = DemandLedger()
        let weight = PlanWeight(session: 20, weekly: 7)
        func reading(session: Double, weekly: Double, at date: Date) -> PoolAccount {
            PoolAccount(id: "a@example.com", weight: weight, limits: [
                UsageLimit(kind: .session, usedPercent: session, resetsAt: ledgerStart + 4 * 3600),
                UsageLimit(kind: .weeklyAll, usedPercent: weekly, resetsAt: ledgerStart + 6 * 86400),
            ], readAt: date)
        }
        ledger.record(reading(session: 10, weekly: 30, at: ledgerStart), pool: "claude", shortWindow: 5 * 3600)
        ledger.record(reading(session: 20, weekly: 32, at: ledgerStart + 60), pool: "claude", shortWindow: 5 * 3600)

        #expect(ledger.totals(pool: "claude", kind: .session).units == 20 * 10)
        #expect(ledger.totals(pool: "claude", kind: .weekly).units == 7 * 2)
    }

    /// Weekly demand recorded before plans had a weekly size is in 5-hour weights, which would
    /// overstate the weekly pace against weekly weights; it's dropped, and the rest kept.
    @Test func aLedgerFromBeforeWeeklyWeightsDropsOnlyItsWeeklyDemand() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 10)
        var ledger = run.ledger
        ledger.record(UsageLimit(kind: .weeklyAll, usedPercent: 10, resetsAt: ledgerStart + 6 * 86400), readAt: run.now - 60, pool: "claude", kind: .weekly, account: "a", weight: 20, window: 7 * 86400)
        ledger.record(UsageLimit(kind: .weeklyAll, usedPercent: 12, resetsAt: ledgerStart + 6 * 86400), readAt: run.now, pool: "claude", kind: .weekly, account: "a", weight: 20, window: 7 * 86400)
        #expect(ledger.totals(pool: "claude", kind: .weekly).units > 0)

        var saved = try #require(try JSONSerialization.jsonObject(with: ledger.encoded()) as? [String: Any])
        saved["version"] = 1
        let loaded = DemandLedger.load(from: try JSONSerialization.data(withJSONObject: saved))

        #expect(loaded.totals(pool: "claude", kind: .session).units == ledger.totals(pool: "claude", kind: .session).units)
        #expect(loaded.totals(pool: "claude", kind: .weekly).units == 0)
        #expect(loaded.observedTime(until: run.now) == ledger.observedTime(until: run.now))
    }

    @Test func aResetMidWindowAddsTheUseAfterItNeverANegative() {
        var run = LedgerRun(weights: ["a": 5])
        run.used["a"] = 80
        run.resets["a"] = ledgerStart + 10 * 60
        run.poll()
        run.burn(["a": 120], minutes: 0.5)
        #expect(run.totals.units == 5)

        run.now = ledgerStart + 15 * 60
        run.used["a"] = 5
        run.resets["a"] = run.now + 5 * 60 * 60 - 60
        let before = run.totals.units
        run.poll()

        #expect(run.totals.units == before + 25)
    }

    @Test func useFallingUnderTheSameResetCountsAsNothing() {
        var run = LedgerRun(weights: ["a": 5])
        run.used["a"] = 40
        run.poll()
        run.now += 30
        run.used["a"] = 35
        run.poll()

        #expect(run.totals.units == 0)
    }

    @Test func aNewAccountsFirstReadingIsNotDemand() {
        var run = LedgerRun(weights: ["a": 5, "b": 20])
        run.used["b"] = 50
        run.poll()

        #expect(run.totals.units == 0)
        #expect(run.totals.events == 0)
    }

    @Test func readingsFromBeforeAClockStepBackAreDroppedAndTheCursorRestarts() {
        var run = LedgerRun(weights: ["a": 5])
        run.burn(["a": 15], minutes: 10)
        let before = run.totals
        let observed = run.ledger.observedTime(until: run.now + 3600)

        run.now -= 60 * 60
        run.used["a"]! += 2
        run.poll()
        #expect(run.totals.units == before.units)
        #expect(run.ledger.observedTime(until: run.now + 2 * 3600) == observed)

        run.now += 30
        run.used["a"]! += 1
        run.poll()
        #expect(run.totals.units == before.units + 5)
    }

    @Test func sleepAddsNoObservedTimeAndNoDemand() {
        var run = LedgerRun(weights: ["a": 5])
        run.poll()
        run.idle(minutes: 10)
        #expect(run.ledger.observedTime(until: run.now) == 600)

        run.away(minutes: 180)
        run.poll()

        #expect(run.ledger.observedTime(until: run.now) == 600)
        #expect(run.totals.units == 0)
    }

    /// The first poll after waking still carries the proxy's old reading; use outside the proxy
    /// (claude.ai, a phone) shows up only in the next one.
    @Test func useWhileEbbWasNotWatchingIsKeptApartFromWatchedUse() {
        var run = LedgerRun(weights: ["a": 5])
        run.poll()
        run.away(minutes: 180)
        run.ledger.heartbeat(at: run.now)
        run.record("a", at: ledgerStart)
        run.now += 60
        run.used["a"] = 10
        run.poll()

        #expect(run.totals.units == 0)
        #expect(run.totals.unwatched == 50)
    }

    /// Limits also move with use outside the proxy, so an unchanged proxy signal doesn't prove
    /// nothing was used: a jump is spread over the whole stretch it may have built up in.
    @Test func useIsSpreadOverTheStretchItBuiltUpIn() throws {
        var run = LedgerRun(weights: ["a": 5])
        run.poll()
        for _ in 0..<80 {
            run.now += 30
            run.ledger.heartbeat(at: run.now)
            run.record("a", at: ledgerStart)
        }
        run.now += 30
        run.used["a"] = 4
        run.poll()

        let last = try #require(run.ledger.bin(pool: run.pool, kind: .session, at: run.now))
        #expect(last.units < 1)
        #expect(abs(run.totals.units - 20) < 0.000_001)
    }

    @Test func aResetSeenEarlyByASkewedClockStillStartsANewCycle() {
        var run = LedgerRun(weights: ["a": 5])
        run.used["a"] = 60
        run.resets["a"] = ledgerStart + 3 * 60
        run.poll()

        run.now = ledgerStart + 60
        run.used["a"] = 5
        run.resets["a"] = run.now + 5 * 60 * 60 - 5 * 60
        run.poll()

        #expect(run.totals.units == 25)
    }

    @Test func aResetFurtherOutThanTheWindowIsIgnored() {
        var run = LedgerRun(weights: ["a": 5])
        run.used["a"] = 50
        run.poll()

        run.now += 30
        run.used["a"] = 5
        run.resets["a"] = run.now + 5 * 60 * 60 + 11 * 60
        run.poll()

        #expect(run.totals.units == 0)
    }

    @Test func binsOlderThanFourteenDaysAreDropped() {
        var run = LedgerRun(weights: ["a": 5])
        run.burn(["a": 12], minutes: 10)
        #expect(run.totals.units > 0)

        run.away(minutes: 15 * 24 * 60)
        run.poll()
        run.idle(minutes: 1)

        #expect(run.totals.units == 0)
        #expect(run.ledger.observedTime(until: run.now) == 60)
    }

    @Test func aCorruptOrOutdatedFileStartsEmpty() throws {
        #expect(DemandLedger.load(from: Data("not json".utf8)) == DemandLedger())
        var run = LedgerRun(weights: ["a": 5])
        run.burn(["a": 12], minutes: 10)
        var object = try #require(try JSONSerialization.jsonObject(with: run.ledger.encoded()) as? [String: Any])
        object["version"] = 99
        #expect(DemandLedger.load(from: try JSONSerialization.data(withJSONObject: object)) == DemandLedger())
    }

    @Test func aSavedLedgerPicksUpWhereItLeftOff() {
        var run = LedgerRun(weights: ["a": 5])
        run.burn(["a": 12], minutes: 10)
        let units = run.totals.units

        run.ledger = DemandLedger.load(from: run.ledger.encoded())
        run.now += 30
        run.used["a"]! += 1
        run.poll()

        #expect(abs(run.totals.units - (units + 5)) < 0.000_001)
    }

    @Test func theSavedLedgerNeverHoldsAnAccountsEmail() {
        var run = LedgerRun(weights: ["person@example.com": 5])
        run.burn(["person@example.com": 12], minutes: 10)

        #expect(!String(decoding: run.ledger.encoded(), as: UTF8.self).contains("example.com"))
    }

    @Test func forgottenAccountsStartOverButTheirDemandStays() {
        var run = LedgerRun(weights: ["a": 5])
        run.burn(["a": 12], minutes: 10)
        let units = run.totals.units

        run.ledger.keepAccounts([], in: run.pool)
        run.now += 30
        run.used["a"]! += 30
        run.poll()

        #expect(run.totals.units == units)
    }
}

@Suite(.hangLimit) struct DemandLedgerReboundTests {
    /// syrtis#367: a reset time that drifts by seconds is the same window, not a new one.
    @Test func aResetTimeThatDriftsBySecondsStaysOneWindow() {
        var run = LedgerRun(weights: ["a": 5], kind: .weekly)
        run.used["a"] = 73
        run.resets["a"] = ledgerStart + 60
        run.poll()

        run.now = ledgerStart + 62
        run.resets["a"] = ledgerStart + 65
        run.poll()

        #expect(run.totals.units == 0)
    }

    /// CodexBar#2230: after a refill, the source briefly returns the stale pre-refill value.
    @Test func aStaleReboundAfterARefillIsNotDemand() {
        var run = LedgerRun(weights: ["a": 5], kind: .weekly)
        run.used["a"] = 73
        run.poll()
        for used in [0.0, 73, 0, 2] {
            run.now += 15
            run.used["a"] = used
            run.poll()
        }

        #expect(run.totals.units == 10)
    }
}

@Suite(.hangLimit) struct DemandLedgerBogusSampleTests {
    /// CodexBar#2222: one bogus near-zero sample, then the real level again.
    @Test func aBogusLowSampleIsNotARefill() {
        var run = LedgerRun(weights: ["a": 5], kind: .weekly)
        run.used["a"] = 73
        run.poll()
        for used in [0.0, 73, 74] {
            run.now += 15
            run.used["a"] = used
            run.poll()
        }

        #expect(run.totals.units == 5)
    }
}
