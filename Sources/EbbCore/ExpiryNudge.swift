import Foundation

/// "Use it or lose it": one alert per weekly reset when weekly capacity is about to reset
/// unused. Accounts whose weekly window resets within `window` count with their free share;
/// a weekly pace that runs the pool out before then means it gets used, so nothing is said.
public struct ExpiryNudge: Codable, Sendable, Equatable {
    /// How far ahead a reset counts as about to happen.
    public static let window: TimeInterval = 24 * 60 * 60
    /// Pool points left unused worth an alert.
    public static let minimumUnused = 20.0
    /// Reset times this close are one cycle; they drift by seconds between readings.
    static let sameCycle: TimeInterval = 6 * 60 * 60

    /// The reset each pool was last nudged about.
    private var nudged: [String: Date] = [:]

    public init() {}

    /// `totalWeight` is the pool's weekly weight: what resets unused is a share of the weekly pool.
    public mutating func alerts(
        pool: String, title: String, accounts: [PoolAccount], totalWeight: Double,
        forecast: Pace.Forecast?, now: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent
    ) -> [PoolAlert] {
        nudged = nudged.filter { $0.value > now - Self.sameCycle }
        guard totalWeight > 0 else { return [] }
        var unused = 0.0
        var resets: [Date] = []
        for account in accounts {
            guard let limit = account.limits.first(where: { $0.kind == .weeklyAll }), let resetsAt = limit.resetsAt,
                  resetsAt > now, resetsAt.timeIntervalSince(now) <= Self.window
            else { continue }
            unused += account.weight.weekly * (100 - limit.used(at: now)) / totalWeight
            resets.append(resetsAt)
        }
        guard let firstReset = resets.min(), let lastReset = resets.max(), unused.rounded() >= Self.minimumUnused else { return [] }
        // The pace counts resets as capacity coming back, so only a run-out before the first one uses it all.
        if case let .runsOut(_, within) = forecast?.outlook, now + within.upperBound <= firstReset { return [] }
        // Accounts entering or leaving the window move the group's last reset; it's still this cycle.
        if let previous = nudged[pool] {
            nudged[pool] = max(previous, lastReset)
            return []
        }
        nudged[pool] = lastReset
        let points = Int(unused.rounded())
        return [PoolAlert(
            id: "expiry.\(pool).\(Int(lastReset.timeIntervalSince1970))",
            title: Localization.text("\(title): \(points)% of this week's pool resets unused \(Self.moment(lastReset, now: now, timeZone: timeZone, locale: locale))", locale: locale),
            body: Localization.text("Work started before then can still use it.", locale: locale)
        )]
    }

    /// "today 10:00 PM", "tomorrow 10:00 PM", or a weekday when a day-long window spans two midnights,
    /// with the clock as the locale writes it.
    static func moment(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = ClockText.time(date, locale: locale, timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return Localization.text("today \(time)", locale: locale) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return Localization.text("tomorrow \(time)", locale: locale)
        }
        return ClockText.weekdayAndTime(date, locale: locale, timeZone: timeZone)
    }
}
