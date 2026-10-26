import Foundation

/// A forecast in words, Battery style: rounded, quiet, always "at this pace" when it
/// stands alone, since the next burst can change it.
public enum PaceText {
    /// The line under the meter, which takes the place of the "+N%" line. Only a run-out
    /// earns it: "About 2 h 10 min left", "1–2 h left", "Runs out ~Thu 14:00".
    public static func inline(_ forecast: Pace.Forecast, window: PoolWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard case let .runsOut(within) = forecast.outlook else { return nil }
        switch window {
        case .session: return "\(span(within)) left"
        case .weekly: return "Runs out ~\(dayAndTime(now + within.lowerBound, timeZone: timeZone, locale: locale))"
        }
    }

    /// The hover card's sentence, for every outlook.
    public static func sentence(_ forecast: Pace.Forecast, window: PoolWindow, short: ShortWindow, now: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        switch (forecast.outlook, window) {
        case let (.runsOut(within), .session):
            "\(span(within)) left at this pace"
        case let (.runsOut(within), .weekly):
            "Runs out around \(dayAndTime(now + within.lowerBound, timeZone: timeZone, locale: locale)) at this pace"
        case (.lasts, .session):
            "Lasts through the next \(short == .day ? "24" : "5") hours at this pace"
        case (.lasts, .weekly):
            "Lasts until reset at this pace"
        }
    }

    /// What the pace rests on: "Based on 45 min of activity", "Based on the last 5 days".
    public static func basis(_ forecast: Pace.Forecast, window: PoolWindow) -> String {
        switch window {
        case .session:
            return "Based on \(duration(forecast.basis).lowercased()) of activity"
        case .weekly:
            let days = min(7, max(1, Int((forecast.basis / 86400).rounded())))
            return days == 1 ? "Based on the last day" : "Based on the last \(days) days"
        }
    }

    /// "About 2 h 10 min", "Under 10 min", or a range: "1–2 h", "20–35 min", "45 min–2 h".
    static func span(_ within: ClosedRange<TimeInterval>) -> String {
        guard within.lowerBound < within.upperBound else {
            let text = duration(within.lowerBound)
            return text.hasPrefix("Under") ? text : "About \(text)"
        }
        let low = within.lowerBound / 60
        let high = within.upperBound / 60
        if high < 60 { return "\(roundedMinutes(low))–\(roundedMinutes(high)) min" }
        let highHours = Int((high / 60).rounded(.up))
        if roundedMinutes(low) < 60 { return "\(roundedMinutes(low)) min–\(highHours) h" }
        return "\(max(1, Int((low / 60).rounded(.down))))–\(highHours) h"
    }

    /// Under 10 minutes says so; under an hour rounds to 5 minutes; then hours and 5 minutes
    /// up to 6 hours, and hours and half hours beyond.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 10 { return "Under 10 min" }
        if minutes < 60 {
            let rounded = roundedMinutes(minutes)
            return rounded >= 60 ? "1 h" : "\(rounded) min"
        }
        let step = minutes < 6 * 60 ? 5.0 : 30.0
        let total = Int((minutes / step).rounded() * step)
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }

    private static func roundedMinutes(_ minutes: Double) -> Int {
        max(5, Int((minutes / 5).rounded() * 5))
    }

    /// To the nearest hour, as the "+N% · Tue 22:00" line writes it.
    private static func dayAndTime(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let hour = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded() * 3600)
        let weekday = hour.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated))
        let time = hour.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        return "\(weekday) \(time)"
    }
}
