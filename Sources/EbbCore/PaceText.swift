import Foundation

/// A forecast in words, Battery style: rounded, quiet, always "at this pace" when it
/// stands alone, since the next burst can change it.
public enum PaceText {
    /// The line under the meter, which takes the place of the "+N%" line. Only a run-out
    /// earns it: "About 2 h 10 min left", "Under 10 min left", "Runs out ~Thu 14:00".
    public static func inline(_ forecast: Pace.Forecast, window: PoolWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard case let .runsOut(time, within) = forecast.outlook else { return nil }
        switch window {
        case .session:
            guard let text = estimate(time, within: within, locale: locale) else { return Localization.text("Under 10 min left", locale: locale) }
            return Localization.text("About \(text) left", locale: locale)
        case .weekly:
            return Localization.text("Runs out ~\(dayAndTime(now + time, timeZone: timeZone, locale: locale))", locale: locale)
        }
    }

    /// The hover card's sentence, for every outlook.
    public static func sentence(_ forecast: Pace.Forecast, window: PoolWindow, short: ShortWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch (forecast.outlook, window) {
        case let (.runsOut(time, within), .session):
            if let text = estimate(time, within: within, locale: locale) {
                Localization.text("About \(text) left at this pace", locale: locale)
            } else {
                Localization.text("Under 10 min left at this pace", locale: locale)
            }
        case let (.runsOut(time, _), .weekly):
            Localization.text("Runs out around \(dayAndTime(now + time, timeZone: timeZone, locale: locale)) at this pace", locale: locale)
        case (.lasts, .session):
            Localization.text("Lasts through the next \(short == .day ? 24 : 5) hours at this pace", locale: locale)
        case (.lasts, .weekly):
            Localization.text("Lasts until reset at this pace", locale: locale)
        }
    }

    /// The weekly card's budget line: "About 14% a day lasts until Tue 10:00 PM". `nil` while
    /// there's nothing to pace; see `WeeklyBudget`.
    public static func budget(_ budget: WeeklyBudget, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let percent = budget.percentPerDay(at: now) else { return nil }
        return Localization.text("About \(percent)% a day lasts until \(ClockText.weekdayAndTime(budget.resetsAt, locale: locale, timeZone: timeZone))", locale: locale)
    }

    /// What the pace rests on: "Based on 45 min of activity", "Based on the last 5 days".
    public static func basis(_ forecast: Pace.Forecast, window: PoolWindow, locale: Locale = .autoupdatingCurrent) -> String {
        switch window {
        case .session:
            return Localization.text("Based on \(duration(forecast.basis, locale: locale).lowercased(with: locale)) of activity", locale: locale)
        case .weekly:
            let days = min(7, max(1, Int((forecast.basis / 86400).rounded())))
            return days == 1 ? Localization.text("Based on the last day", locale: locale) : Localization.text("Based on the last \(days) days", locale: locale)
        }
    }

    /// The main pace's run-out, as precise as the paces agree, the way Battery's time remaining
    /// says less when it knows less instead of giving a range: `duration`'s steps when they agree, the
    /// nearest 15 minutes under an hour and the nearest half hour above when they don't. `nil`
    /// under 10 minutes.
    private static func estimate(_ time: TimeInterval, within: ClosedRange<TimeInterval>, locale: Locale) -> String? {
        let minutes = time / 60
        guard minutes >= 10 else { return nil }
        guard within.lowerBound < within.upperBound else { return duration(time, locale: locale) }
        let step = minutes < 60 ? 15.0 : 30.0
        return hoursAndMinutes(Int((minutes / step).rounded() * step), locale: locale)
    }

    /// Under 10 minutes says so; under an hour rounds to 5 minutes; then hours and 5 minutes
    /// up to 6 hours, and hours and half hours beyond.
    static func duration(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let minutes = seconds / 60
        if minutes < 10 { return Localization.text("Under 10 min", locale: locale) }
        if minutes < 60 { return hoursAndMinutes(roundedMinutes(minutes), locale: locale) }
        let step = minutes < 6 * 60 ? 5.0 : 30.0
        return hoursAndMinutes(Int((minutes / step).rounded() * step), locale: locale)
    }

    /// "45 min", "2 h", "2 h 30 min".
    private static func hoursAndMinutes(_ total: Int, locale: Locale) -> String {
        if total < 60 { return Localization.text("\(total) min", locale: locale) }
        return total % 60 == 0 ? Localization.text("\(total / 60) h", locale: locale) : Localization.text("\(total / 60) h \(total % 60) min", locale: locale)
    }

    private static func roundedMinutes(_ minutes: Double) -> Int {
        max(5, Int((minutes / 5).rounded() * 5))
    }

    /// To the nearest hour, as the "+N% · Tue 22:00" line writes it.
    private static func dayAndTime(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let hour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded() * 3600)
        return ClockText.weekdayAndTime(hour, locale: locale, timeZone: timeZone)
    }
}
