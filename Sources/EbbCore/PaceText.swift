import Foundation

/// A forecast in words, Battery style: rounded, quiet, always "at this pace" when it
/// stands alone, since the next burst can change it.
public enum PaceText {
    /// The line under the meter, which takes the place of the "+N%" line. Only a run-out
    /// earns it: "About 2 h 10 min left", "1–2 h left", "Runs out ~Thu 14:00".
    public static func inline(_ forecast: Pace.Forecast, window: PoolWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard case let .runsOut(within) = forecast.outlook else { return nil }
        switch window {
        case .session:
            return switch span(within, locale: locale) {
            case .under: Localization.text("Under 10 min left", locale: locale)
            case let .about(text): Localization.text("About \(text) left", locale: locale)
            case let .range(text): Localization.text("\(text) left", locale: locale)
            }
        case .weekly:
            return Localization.text("Runs out ~\(dayAndTime(now + within.lowerBound, timeZone: timeZone, locale: locale))", locale: locale)
        }
    }

    /// The hover card's sentence, for every outlook.
    public static func sentence(_ forecast: Pace.Forecast, window: PoolWindow, short: ShortWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch (forecast.outlook, window) {
        case let (.runsOut(within), .session):
            switch span(within, locale: locale) {
            case .under: Localization.text("Under 10 min left at this pace", locale: locale)
            case let .about(text): Localization.text("About \(text) left at this pace", locale: locale)
            case let .range(text): Localization.text("\(text) left at this pace", locale: locale)
            }
        case let (.runsOut(within), .weekly):
            Localization.text("Runs out around \(dayAndTime(now + within.lowerBound, timeZone: timeZone, locale: locale)) at this pace", locale: locale)
        case (.lasts, .session):
            Localization.text("Lasts through the next \(short == .day ? 24 : 5) hours at this pace", locale: locale)
        case (.lasts, .weekly):
            Localization.text("Lasts until reset at this pace", locale: locale)
        }
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

    /// How sure a run-out is: a single time is "About", under ten minutes says so, and a range stands alone.
    private enum Span {
        case under
        case about(String)
        case range(String)
    }

    /// "2 h 10 min" as about, under 10 minutes, or a range: "1–2 h", "20–35 min", "45 min–2 h".
    private static func span(_ within: ClosedRange<TimeInterval>, locale: Locale) -> Span {
        guard within.lowerBound < within.upperBound else {
            return within.lowerBound / 60 < 10 ? .under : .about(duration(within.lowerBound, locale: locale))
        }
        let low = within.lowerBound / 60
        let high = within.upperBound / 60
        if high < 60 { return .range(Localization.text("\(roundedMinutes(low))–\(roundedMinutes(high)) min", locale: locale)) }
        let highHours = Int((high / 60).rounded(.up))
        if roundedMinutes(low) < 60 { return .range(Localization.text("\(roundedMinutes(low)) min–\(highHours) h", locale: locale)) }
        return .range(Localization.text("\(max(1, Int((low / 60).rounded(.down))))–\(highHours) h", locale: locale))
    }

    /// Under 10 minutes says so; under an hour rounds to 5 minutes; then hours and 5 minutes
    /// up to 6 hours, and hours and half hours beyond.
    static func duration(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let minutes = seconds / 60
        if minutes < 10 { return Localization.text("Under 10 min", locale: locale) }
        if minutes < 60 {
            let rounded = roundedMinutes(minutes)
            return rounded >= 60 ? Localization.text("\(1) h", locale: locale) : Localization.text("\(rounded) min", locale: locale)
        }
        let step = minutes < 6 * 60 ? 5.0 : 30.0
        let total = Int((minutes / step).rounded() * step)
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
