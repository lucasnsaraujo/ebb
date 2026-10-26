import Foundation

/// One pool's answer for Shortcuts and Siri, worked out from the saved status at `now`.
public struct PoolAnswer: Sendable, Equatable {
    public struct Refill: Sendable, Equatable {
        /// "5-hour", "daily" or "weekly".
        public var window: String
        public var date: Date
        /// Whole points of that window's pool.
        public var gain: Int
    }

    public var provider: String
    public var shortWindowTitle: String
    public var shortWindowFree: Int
    public var weeklyFree: Int
    /// The sooner of the two windows' next refills.
    public var nextRefill: Refill?
    public var isStale: Bool
    public var readAt: Date?
    let now: Date

    /// `provider`'s pool, or the menu bar's; `nil` without saved numbers or such a pool.
    public init?(_ status: PoolStatus?, provider: String?, now: Date) {
        guard let pool = status?.pool(named: provider) else { return nil }
        self.provider = pool.title
        shortWindowTitle = pool.shortWindow.title.lowercased()
        shortWindowFree = StatusReport.whole(pool.session.free(at: now))
        weeklyFree = StatusReport.whole(pool.weekly.free(at: now))
        let refills = [
            pool.session.nextRefill(at: now).map { Refill(window: pool.shortWindow.title.lowercased(), date: $0.date, gain: StatusReport.whole($0.gain)) },
            pool.weekly.nextRefill(at: now).map { Refill(window: "weekly", date: $0.date, gain: StatusReport.whole($0.gain)) },
        ]
        nextRefill = refills.compactMap { $0 }.min { $0.date < $1.date }
        isStale = pool.isStale(at: now)
        readAt = pool.readAt
        self.now = now
    }

    /// "Claude: 88% of the 5-hour pool and 45% of the weekly pool are free. Next refill: +12% of the 5-hour pool at 20:05."
    public func sentence(timeZone: TimeZone = .current) -> String {
        var text = "\(provider): \(shortWindowFree)% of the \(shortWindowTitle) pool and \(weeklyFree)% of the weekly pool are free."
        if let nextRefill {
            let moment = StatusReport.moment(nextRefill.date, now: now, timeZone: timeZone)
            text += " Next refill: +\(nextRefill.gain)% of the \(nextRefill.window) pool \(moment.hasPrefix("at ") ? moment : "on " + moment)."
        }
        if isStale {
            text += readAt.map { " Last read \(RefillText.until(now, now: $0)) ago." } ?? " No recent reading."
        }
        return text
    }
}
