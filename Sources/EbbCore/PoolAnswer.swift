import Foundation

/// One pool's answer for Shortcuts and Siri, worked out from the saved status at `now`.
public struct PoolAnswer: Sendable, Equatable {
    public struct Refill: Sendable, Equatable {
        public var window: PoolWindow
        public var date: Date
        /// Whole points of that window's pool.
        public var gain: Int
    }

    public var provider: String
    public var shortWindow: ShortWindow
    /// "5-hour" or "daily", in the user's language.
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
        shortWindow = pool.shortWindow
        shortWindowTitle = pool.shortWindow.title.lowercased()
        shortWindowFree = StatusReport.whole(pool.session.free(at: now))
        weeklyFree = StatusReport.whole(pool.weekly.free(at: now))
        let refills = [
            pool.session.nextRefill(at: now).map { Refill(window: .session, date: $0.date, gain: StatusReport.whole($0.gain)) },
            pool.weekly.nextRefill(at: now).map { Refill(window: .weekly, date: $0.date, gain: StatusReport.whole($0.gain)) },
        ]
        nextRefill = refills.compactMap { $0 }.min { $0.date < $1.date }
        isStale = pool.isStale(at: now)
        readAt = pool.readAt
        self.now = now
    }

    /// "Claude: 88% of the 5-hour pool and 45% of the weekly pool are left. Next refill: +12% of the 5-hour pool at 8:05 PM."
    public func sentence(timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var text = Localization.text(
            "\(provider): \(shortWindowFree)% of the \(poolName(.session, locale: locale)) and \(weeklyFree)% of the \(poolName(.weekly, locale: locale)) are left.",
            locale: locale
        )
        if let nextRefill {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let pool = poolName(nextRefill.window, locale: locale)
            if calendar.isDate(nextRefill.date, inSameDayAs: now) {
                let time = ClockText.time(nextRefill.date, locale: locale, timeZone: timeZone)
                text += " " + Localization.text("Next refill: +\(nextRefill.gain)% of the \(pool) at \(time).", locale: locale)
            } else {
                let day = ClockText.weekdayAndTime(nextRefill.date, locale: locale, timeZone: timeZone)
                text += " " + Localization.text("Next refill: +\(nextRefill.gain)% of the \(pool) on \(day).", locale: locale)
            }
        }
        if isStale {
            text += " " + (readAt.map { Localization.text("Last read \(RefillText.until(now, now: $0, locale: locale)) ago.", locale: locale) }
                ?? Localization.text("No recent reading.", locale: locale))
        }
        return text
    }

    /// "5-hour pool", "daily pool" or "weekly pool".
    private func poolName(_ window: PoolWindow, locale: Locale) -> String {
        switch (window, shortWindow) {
        case (.session, .fiveHours): Localization.text("5-hour pool", locale: locale)
        case (.session, .day): Localization.text("daily pool", locale: locale)
        case (.weekly, _): Localization.text("weekly pool", locale: locale)
        }
    }
}
