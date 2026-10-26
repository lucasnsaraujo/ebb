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

@Suite struct DemandLedgerTests {
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
