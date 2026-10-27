import Foundation

/// What VoiceOver says for the panel's meters and account rows. Percentages are spelled out,
/// so a row never reads as a string of bare numbers.
public enum AccessibilityText {
    /// "88 percent free", with what comes back within the window when something does.
    public static func meter(freePercent: Int, comingBackPercent: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard comingBackPercent > 0 else { return Localization.text("\(freePercent) percent free", locale: locale) }
        return Localization.text("\(freePercent) percent free, \(comingBackPercent) percent coming back", locale: locale)
    }

    /// An account's window: its free share, or why there's no bar to read.
    public static func miniMeter(freePercent: Int?, isUncapped: Bool, locale: Locale = .autoupdatingCurrent) -> String {
        if let freePercent { return Localization.text("\(freePercent) percent free", locale: locale) }
        return Localization.text(isUncapped ? "no weekly limit" : "no reading", locale: locale)
    }

    /// Name, plan, status, both windows and share, in that order, as one row.
    public static func accountRow(
        name: String, plan: String?, status: String, short: ShortWindow,
        sessionFree: Int?, weeklyFree: Int?, hasNoWeeklyCap: Bool, share: Int?, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let windows = [
            (short.title(locale: locale), miniMeter(freePercent: sessionFree, isUncapped: false, locale: locale)),
            (Localization.text("Weekly", locale: locale), miniMeter(freePercent: weeklyFree, isUncapped: hasNoWeeklyCap, locale: locale)),
        ].map { Localization.text("\($0.0): \($0.1)", locale: locale) }
        let share = share.map { Localization.text("share \($0) percent", locale: locale) } ?? Localization.text("no share", locale: locale)
        return ([name, plan, status].compactMap { $0 } + windows + [share]).joined(separator: ", ")
    }
}
