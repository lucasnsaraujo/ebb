import Foundation

/// When a pool runs out at the pace it's being used. Like Battery's time remaining, it gives
/// a number only when the evidence is good, and says nothing otherwise: idle, too little
/// history, a pool that's mostly unread, or a clock that stepped back.
///
/// The 5-hour pace is the recent rate while working, with idle time left out, so a lunch break
/// doesn't read as "lasts". The weekly pace is the usual rhythm, idle time included, so nights
/// and weekends count. Neither ever looks at the other's ledger.
public enum Pace {
    public enum Outlook: Sendable, Equatable {
        /// Seconds from now; a range when the recent and the longer pace disagree.
        case runsOut(within: ClosedRange<TimeInterval>)
        case lasts
    }

    public struct Forecast: Sendable, Equatable {
        public var outlook: Outlook
        /// Active time (5-hour) or the span of history (weekly) the pace rests on.
        public var basis: TimeInterval

        public init(outlook: Outlook, basis: TimeInterval) {
            self.outlook = outlook
            self.basis = basis
        }
    }

    /// How far back the 5-hour pace looks.
    static let lookback: TimeInterval = 90 * 60
    /// A bin with more weighted demand than this counts as active.
    static let activeUnits = 0.05
    /// Quiet bins between active ones, up to this many, count as active: thinking, tool runs.
    static let bridgedBins = 2
    /// No use for this long hides the 5-hour pace.
    static let idleAfter: TimeInterval = 10 * 60
    static let minimumActiveTime: TimeInterval = 15 * 60
    static let minimumEvents = 2
    /// Pool points used within the lookback; a single 1% step on one account is less.
    static let minimumPoints = 1.0
    /// Half-lives of the fast, main and slow 5-hour paces.
    static let halfLives: (fast: TimeInterval, main: TimeInterval, slow: TimeInterval) = (10 * 60, 20 * 60, 45 * 60)
    /// Fast and slow run-outs this far apart show a range instead of one time.
    public static let bracketRatio = 1.5

    static let weeklyLookback: TimeInterval = 7 * 24 * 60 * 60
    static let weeklyHalfLife: TimeInterval = 2 * 24 * 60 * 60
    static let minimumObservedTime: TimeInterval = 24 * 60 * 60
    static let minimumEpisodes = 3
    /// Active stretches further apart than this are separate episodes.
    static let episodeGap: TimeInterval = 30 * 60
    /// No use for this long means the rhythm is stale: a vacation, a switch to other tools.
    static let staleAfter: TimeInterval = 48 * 60 * 60
    /// A partly read pool shows a pace only when at least this share of its accounts was read.
    static let minimumReadableShare = 0.8
    /// Below this the pool shows 0% free, and its usual line says when capacity returns.
    static let minimumFree = 0.5

    /// The 5-hour pool. `horizon` is the window's length: five hours, or a day for Devin.
    public static func session(_ ledger: DemandLedger, pool: String, summary: PoolSummary, horizon: TimeInterval, now: Date) -> Forecast? {
        guard isReadable(summary), summary.session.freePercent >= minimumFree, !ledger.isAhead(of: now) else { return nil }
        let slots = ledger.slots(pool: pool, kind: .session, from: now - lookback + DemandLedger.binLength, to: now)
        let active = slots.map { $0.units > activeUnits }
        guard let lastActive = active.lastIndex(of: true),
              now.timeIntervalSince(DemandLedger.start(of: slots[lastActive].bin + 1)) <= idleAfter
        else { return nil }

        var included = active
        var previous: Int?
        for index in active.indices where active[index] {
            if let previous, index - previous - 1 <= bridgedBins {
                for gap in (previous + 1)..<index { included[gap] = true }
            }
            previous = index
        }
        let used = slots.indices.filter { included[$0] && slots[$0].observed > 0 }.map { slots[$0] }
        let activeTime = used.reduce(0) { $0 + $1.observed }
        let events = used.reduce(0) { $0 + $1.events }
        let units = used.reduce(0) { $0 + $1.units }
        guard activeTime >= minimumActiveTime, events >= minimumEvents, units / summary.totalWeight.session >= minimumPoints else { return nil }

        func rate(halfLife: TimeInterval) -> Double {
            ewmaRate(used, halfLife: halfLife, now: now) / summary.totalWeight.session
        }
        let window = summary.session
        func runOut(_ rate: Double) -> TimeInterval? {
            timeToEmpty(free: window.freePercent, resets: window.resets, rate: rate, horizon: horizon, now: now)
        }
        guard let main = runOut(rate(halfLife: halfLives.main)) else { return Forecast(outlook: .lasts, basis: activeTime) }
        let others = [halfLives.fast, halfLives.slow].map { runOut(rate(halfLife: $0)) ?? horizon }
        let low = min(main, others.min() ?? main)
        let high = max(main, others.max() ?? main)
        let within = high / max(low, 1) >= bracketRatio ? low...high : main...main
        return Forecast(outlook: .runsOut(within: within), basis: activeTime)
    }

    /// The weekly pool, at its usual rhythm over the last week.
    public static func weekly(_ ledger: DemandLedger, pool: String, summary: PoolSummary, now: Date) -> Forecast? {
        let window = summary.weekly
        // An account with no weekly cap keeps the pool from ever running out.
        guard isReadable(summary), window.uncappedPercent == 0, window.freePercent >= minimumFree, !ledger.isAhead(of: now) else { return nil }
        let slots = ledger.slots(pool: pool, kind: .weekly, from: now - weeklyLookback + DemandLedger.binLength, to: now)
            .filter { $0.observed > 0 || $0.unwatched > 0 }
        let observedTime = slots.reduce(0) { $0 + $1.observed }
        let activeBins = slots.filter { $0.units + $0.unwatched > activeUnits }.map(\.bin)
        guard observedTime >= minimumObservedTime,
              let lastActive = activeBins.last,
              now.timeIntervalSince(DemandLedger.start(of: lastActive + 1)) <= staleAfter
        else { return nil }
        let gapBins = Int(episodeGap / DemandLedger.binLength)
        let episodes = 1 + zip(activeBins, activeBins.dropFirst()).filter { $1 - $0 - 1 > gapBins }.count
        guard episodes >= minimumEpisodes else { return nil }

        let rate = ewmaRate(slots.map { slot in
            var slot = slot
            slot.units += slot.unwatched
            return slot
        }, halfLife: weeklyHalfLife, now: now) / summary.totalWeight.weekly
        let basis = slots.first.map { now.timeIntervalSince(DemandLedger.start(of: $0.bin)) } ?? 0
        guard let time = timeToEmpty(free: window.freePercent, resets: window.resets, rate: rate, horizon: weeklyLookback, now: now) else {
            return Forecast(outlook: .lasts, basis: basis)
        }
        return Forecast(outlook: .runsOut(within: time...time), basis: basis)
    }

    private static func isReadable(_ summary: PoolSummary) -> Bool {
        summary.totalWeight.isPositive && (!summary.isPartial || summary.readableShare >= minimumReadableShare)
    }

    /// Weighted demand per observed hour, recent bins counting most.
    private static func ewmaRate(_ slots: [DemandLedger.Slot], halfLife: TimeInterval, now: Date) -> Double {
        var demand = 0.0
        var hours = 0.0
        for slot in slots where slot.observed > 0 {
            let middle = DemandLedger.start(of: slot.bin) + slot.observed / 2
            let weight = pow(0.5, max(0, now.timeIntervalSince(middle)) / halfLife)
            demand += weight * slot.units
            hours += weight * slot.observed / 3600
        }
        return hours > 0 ? demand / hours : 0
    }

    /// When the pool reaches zero, using `rate` points an hour and getting each reset back
    /// as it lands; `nil` if it lasts past `horizon`.
    static func timeToEmpty(free: Double, resets: [Restoration], rate: Double, horizon: TimeInterval, now: Date) -> TimeInterval? {
        guard rate > 0 else { return nil }
        var left = min(free, 100)
        var elapsed = 0.0
        for reset in resets.sorted(by: { $0.date < $1.date }) {
            let gap = reset.date.timeIntervalSince(now) - elapsed
            guard gap > 0 else {
                left = min(100, left + reset.gain)
                continue
            }
            if left - rate * gap / 3600 <= 0 { break }
            left -= rate * gap / 3600
            elapsed += gap
            guard elapsed < horizon else { return nil }
            left = min(100, left + reset.gain)
        }
        let time = elapsed + left / rate * 3600
        return time <= horizon ? time : nil
    }
}

/// When each window of a pool runs out at the current pace; `nil` while there's too little to go on.
public struct PoolForecast: Sendable, Equatable {
    public var session: Pace.Forecast?
    public var weekly: Pace.Forecast?

    public init(session: Pace.Forecast? = nil, weekly: Pace.Forecast? = nil) {
        self.session = session
        self.weekly = weekly
    }

    public init(ledger: DemandLedger, pool summary: PoolSummary, provider: String, now: Date) {
        let horizon = Providers.named(provider)?.shortWindow.horizon ?? Pool.sessionHorizon
        session = Pace.session(ledger, pool: provider, summary: summary, horizon: horizon, now: now)
        weekly = Pace.weekly(ledger, pool: provider, summary: summary, now: now)
    }
}
