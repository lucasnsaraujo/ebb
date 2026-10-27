import Foundation

/// The small print under a hover card: how old the numbers are, what's left out of them,
/// and, for the 5-hour window, accounts whose spent week takes them out of it.
public enum PoolNotes {
    /// What stands in for an empty "+N%" line under the 5-hour meter: why the pool is low.
    public static func inline(_ summary: PoolSummary) -> String? {
        summary.weeklyLimitedAccounts > 0 ? "\(summary.weeklyLimitedAccounts) of \(summary.readAccounts) at weekly limit" : nil
    }

    public static func lines(_ summary: PoolSummary, window: PoolWindow, now: Date) -> [String] {
        var lines: [String] = []
        if window == .session, summary.weeklyLimitedAccounts > 0 {
            lines.append(summary.readAccounts == 1
                ? "Its only account is at its weekly limit"
                : "\(summary.weeklyLimitedAccounts) of \(summary.readAccounts) accounts at their weekly limit")
        }
        if let oldest = summary.oldestReadingAt {
            lines.append("As of \(age(of: oldest, now: now))")
        }
        if summary.unreadAccounts > 0 {
            lines.append(summary.unreadAccounts == 1 ? "1 account can't be read right now" : "\(summary.unreadAccounts) accounts can't be read right now")
        }
        return lines
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}
