import Foundation

/// The small print under a hover card: how old the numbers are once that's worth saying, what's
/// left out of them, and, for the 5-hour window, accounts whose spent week takes them out of it.
public enum PoolNotes {
    /// A locked share under this many points stays off the meter's lines.
    public static let lockedShownFrom = 5.0

    /// Why the 5-hour meter reads lower than its accounts: "57% locked until Tue 10:00 PM".
    /// `nil` while less than `lockedShownFrom` is locked.
    public static func locked(_ window: WindowSummary, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard window.lockedPercent >= lockedShownFrom else { return nil }
        let percent = Int(window.lockedPercent.rounded())
        guard let unlocksAt = window.unlocksAt else { return Localization.text("\(percent)% locked until the weekly reset", locale: locale) }
        return Localization.text("\(percent)% locked until \(ClockText.weekdayAndTime(unlocksAt, locale: locale, timeZone: timeZone))", locale: locale)
    }

    /// What stands in for an empty "+N%" line under the 5-hour meter: why the pool is low.
    public static func inline(_ summary: PoolSummary, locale: Locale = .autoupdatingCurrent) -> String? {
        summary.weeklyLimitedAccounts > 0 ? Localization.text("\(summary.weeklyLimitedAccounts) of \(summary.readAccounts) at weekly limit", locale: locale) : nil
    }

    public static func lines(_ summary: PoolSummary, window: PoolWindow, now: Date, locale: Locale = .autoupdatingCurrent) -> [String] {
        var lines: [String] = []
        if window == .session, summary.weeklyLimitedAccounts > 0 {
            lines.append(summary.readAccounts == 1
                ? Localization.text("Its only account is at its weekly limit", locale: locale)
                : Localization.text("\(summary.weeklyLimitedAccounts) of \(summary.readAccounts) accounts at their weekly limit", locale: locale))
        }
        // The accounts footer says when the proxy last answered, so the age is repeated only once
        // the menu bar would dim for it; see `MenuBarItem.staleAfter`.
        if let oldest = summary.oldestReadingAt, now.timeIntervalSince(oldest) > MenuBarItem.staleAfter {
            lines.append(Localization.text("As of \(age(of: oldest, now: now, locale: locale))", locale: locale))
        }
        if summary.unreadAccounts > 0 {
            lines.append(Localization.text("\(summary.unreadAccounts) accounts can't be read right now", locale: locale))
        }
        return lines
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    static func age(of date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return Localization.text("\(seconds) s ago", locale: locale) }
        if seconds < 3600 { return Localization.text("\(seconds / 60) min ago", locale: locale) }
        return Localization.text("\(seconds / 3600) h ago", locale: locale)
    }
}
