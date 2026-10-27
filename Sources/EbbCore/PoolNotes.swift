import Foundation

/// The small print under a hover card: how old the numbers are, what's left out of them,
/// and, for the 5-hour window, accounts whose spent week takes them out of it.
public enum PoolNotes {
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
        if let oldest = summary.oldestReadingAt {
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
