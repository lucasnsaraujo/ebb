import Foundation

/// Clock times as the locale writes them, with its 12- or 24-hour cycle and its leading zero:
/// "1:15 AM" in US English, "01:15" in Brazilian Portuguese. The shortened time style drops
/// the zero, and a bare "1:15" beside "in 41 min" reads like a duration.
public enum ClockText {
    public static func time(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute())
    }

    /// "Tue 10:00 PM", "ter. 22:00".
    public static func weekdayAndTime(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let weekday = date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated))
        return "\(weekday) \(time(date, locale: locale, timeZone: timeZone))"
    }
}
