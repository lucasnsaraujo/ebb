import CryptoKit
import Foundation

/// How fast each pool is being used, in 5-minute bins over the last 14 days: one series per
/// provider pool and window, never mixed. Demand is kept in weighted units, plan weight ×
/// percentage points used, so adding, retiring or resetting an account leaves history alone;
/// dividing by the pool's current weight turns it into pool points.
///
/// Only increases count: a reset adds the use after it, and a falling reading adds nothing.
/// Time Ebb wasn't polling (asleep, quit, hidden) is unobserved, so sleep never reads as idle.
/// A stretch like that which ends with use was partly awake: it counts toward the weekly
/// rhythm, never toward the 5-hour pace.
public struct DemandLedger: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case session, weekly
    }

    public static let binLength: TimeInterval = 5 * 60
    public static let retention: TimeInterval = 14 * 24 * 60 * 60
    /// Polls further apart than this leave the time between them unobserved.
    public static let heartbeatGap: TimeInterval = 90
    /// A change that built up over longer than this happened while Ebb wasn't watching.
    public static let watchedSpan: TimeInterval = 90 * 60
    /// A reset this much later than the one on record starts a new cycle, even when the
    /// Mac's clock hasn't reached the old one yet.
    static let cycleShift: TimeInterval = 30 * 60
    /// A reset further out than the window plus this is a bad reading, and is ignored.
    static let resetSlack: TimeInterval = 10 * 60
    /// Reset times this close are the same reset: providers' times drift by seconds.
    static let resetDrift: TimeInterval = 10 * 60
    /// A fall this big within one window is a refill or a bogus low sample.
    static let bigDrop = 10.0
    /// A reading back at the level before a big fall, this soon, is a stale or bogus sample
    /// on one side of the fall: the change counts as nothing either way.
    static let reboundWindow: TimeInterval = 30 * 60
    static let currentVersion = 1

    struct Bin: Codable, Sendable, Equatable {
        /// Demand seen while Ebb was watching.
        var units = 0.0
        /// Increases that ended in this bin.
        var events = 0
        /// Demand that built up while Ebb wasn't watching, first seen in this bin.
        var unwatched = 0.0
    }

    /// An account's last reading. Use between two readings is spread over the time between
    /// them: an account's limits also move with use outside the proxy (claude.ai, a phone),
    /// which no proxy signal shows, so an unchanged signal doesn't mean nothing was used.
    struct Cursor: Codable, Sendable, Equatable {
        var used: Double
        var resetsAt: Date?
        var at: Date
        /// The level before a big fall within the window, and when it fell.
        var droppedFrom: Double?
        var droppedAt: Date?
    }

    private var version = Self.currentVersion
    /// Seconds Ebb was polling, by bin. Shared by every pool: it's about the Mac, not the account.
    private var observed: [Int: Double] = [:]
    private var lastHeartbeat: Date?
    /// Demand by `pool/kind`, then bin.
    private var series: [String: [Int: Bin]] = [:]
    /// The last reading by `pool/kind/account`, the account hashed so no email lands on disk.
    private var cursors: [String: Cursor] = [:]

    public init() {}

    /// A saved ledger; empty when the data is unreadable or from another version.
    public static func load(from data: Data) -> DemandLedger {
        guard let ledger = try? JSONDecoder().decode(DemandLedger.self, from: data), ledger.version == currentVersion else { return DemandLedger() }
        return ledger
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func bin(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / binLength).rounded(.down))
    }

    static func start(of bin: Int) -> Date {
        Date(timeIntervalSince1970: Double(bin) * binLength)
    }

    // MARK: - Recording

    /// Called on every poll, whether or not the proxy answered: with the proxy down nothing
    /// can be used through it, so that time is truly idle.
    public mutating func heartbeat(at now: Date) {
        defer { lastHeartbeat = now }
        guard let last = lastHeartbeat, now > last else { return }
        if Self.bin(now) != Self.bin(last) { prune(before: now - Self.retention) }
        guard now.timeIntervalSince(last) <= Self.heartbeatGap else { return }
        forEachBin(from: last, to: now) { bin, seconds in
            observed[bin] = min(Self.binLength, (observed[bin] ?? 0) + seconds)
        }
    }

    /// Records one account's reading of one window. `window` is the window's length, to spot bad resets.
    public mutating func record(_ limit: UsageLimit?, readAt: Date, pool: String, kind: Kind, account: String, weight: Double, window: TimeInterval) {
        let key = "\(pool)/\(kind.rawValue)/\(Self.hashed(account))"
        let resetsAt = limit?.resetsAt.flatMap { $0.timeIntervalSince(readAt) > window + Self.resetSlack ? nil : $0 }
        var reading = Cursor(used: limit?.used(at: readAt) ?? 0, resetsAt: resetsAt, at: readAt)
        guard let previous = cursors[key], readAt >= previous.at else {
            // First reading, or the clock stepped back: start over from here.
            cursors[key] = reading
            return
        }
        guard readAt > previous.at else { return }
        let increase: Double
        if Self.isNewCycle(from: previous, to: reading) {
            increase = reading.used
        } else if reading.used <= previous.used - Self.bigDrop {
            (reading.droppedFrom, reading.droppedAt) = (previous.used, readAt)
            increase = 0
        } else if let from = previous.droppedFrom, let at = previous.droppedAt,
                  readAt.timeIntervalSince(at) <= Self.reboundWindow, reading.used >= from - 1 {
            increase = 0
        } else {
            (reading.droppedFrom, reading.droppedAt) = (previous.droppedFrom, previous.droppedAt)
            increase = max(0, reading.used - previous.used)
        }
        cursors[key] = reading
        let units = weight * increase
        guard units > 0 else { return }

        let start = previous.at
        let seriesKey = "\(pool)/\(kind.rawValue)"
        let last = Self.bin(readAt)
        if readAt.timeIntervalSince(start) <= Self.watchedSpan {
            spread(units, from: start, to: readAt, into: seriesKey)
            series[seriesKey, default: [:]][last, default: Bin()].events += 1
        } else {
            series[seriesKey, default: [:]][last, default: Bin()].unwatched += units
            // The Mac was awake for some of that stretch, since the account was used.
            forEachBin(from: start, to: readAt) { bin, seconds in
                observed[bin] = max(observed[bin] ?? 0, seconds)
            }
        }
    }

    /// Drops the readings of accounts no longer in `pool`, so one that comes back starts
    /// over instead of counting what it used meanwhile. Their demand stays.
    public mutating func keepAccounts(_ accounts: Set<String>, in pool: String) {
        let kept = Set(accounts.map(Self.hashed))
        cursors = cursors.filter { key, _ in
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            return parts.count < 3 || parts[0] != pool || kept.contains(parts[2])
        }
    }

    private static func hashed(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The old window ended: its reset passed, or the reading names a clearly later one. A
    /// reset time a few seconds off the old one is the same window, early or late.
    private static func isNewCycle(from previous: Cursor, to reading: Cursor) -> Bool {
        guard let old = previous.resetsAt else { return false }
        if let new = reading.resetsAt, abs(new.timeIntervalSince(old)) <= resetDrift { return false }
        return old <= reading.at || reading.resetsAt.map { $0 > old + cycleShift } == true
    }

    private mutating func spread(_ units: Double, from start: Date, to end: Date, into key: String) {
        let span = end.timeIntervalSince(start)
        guard span > 0 else {
            series[key, default: [:]][Self.bin(end), default: Bin()].units += units
            return
        }
        forEachBin(from: start, to: end) { bin, seconds in
            series[key, default: [:]][bin, default: Bin()].units += units * seconds / span
        }
    }

    private func forEachBin(from start: Date, to end: Date, _ body: (Int, TimeInterval) -> Void) {
        var time = start.timeIntervalSince1970
        let stop = end.timeIntervalSince1970
        while time < stop {
            let bin = Int((time / Self.binLength).rounded(.down))
            let next = min(Double(bin + 1) * Self.binLength, stop)
            body(bin, next - time)
            time = next
        }
    }

    private mutating func prune(before date: Date) {
        let oldest = Self.bin(date)
        observed = observed.filter { $0.key >= oldest }
        series = series.mapValues { $0.filter { $0.key >= oldest } }
    }

    // MARK: - Reading

    struct Slot {
        var bin: Int
        var units: Double
        var unwatched: Double
        var events: Int
        var observed: TimeInterval
    }

    /// Every bin from `start` to the one holding `end`, oldest first.
    func slots(pool: String, kind: Kind, from start: Date, to end: Date) -> [Slot] {
        let bins = series["\(pool)/\(kind.rawValue)"] ?? [:]
        return (Self.bin(start)...Self.bin(end)).map { id in
            let bin = bins[id] ?? Bin()
            return Slot(bin: id, units: bin.units, unwatched: bin.unwatched, events: bin.events, observed: observed[id] ?? 0)
        }
    }

    /// True while the clock is behind what's recorded, after it stepped back.
    func isAhead(of now: Date) -> Bool {
        (observed.keys.max() ?? .min) > Self.bin(now)
    }

    func bin(pool: String, kind: Kind, at date: Date) -> Bin? {
        series["\(pool)/\(kind.rawValue)"]?[Self.bin(date)]
    }

    func totals(pool: String, kind: Kind) -> (units: Double, unwatched: Double, events: Int) {
        (series["\(pool)/\(kind.rawValue)"] ?? [:]).values.reduce((0, 0, 0)) { ($0.0 + $1.units, $0.1 + $1.unwatched, $0.2 + $1.events) }
    }

    func observedTime(until date: Date) -> TimeInterval {
        observed.filter { $0.key <= Self.bin(date) }.values.reduce(0, +)
    }
}
