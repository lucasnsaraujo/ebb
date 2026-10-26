import EbbCore
import SwiftUI

/// A window's free share, as the UI shows it.
struct PoolLevel {
    let percent: Int

    init(_ freePercent: Double) {
        percent = Int(freePercent.rounded())
    }

    /// `nil` while there is plenty left, so the menu bar stays monochrome.
    var warningTint: Color? {
        switch percent {
        case ..<10: .red
        case ..<20: .orange
        default: nil
        }
    }
}

extension PoolWindow {
    var title: String {
        switch self {
        case .session: "5-hour"
        case .weekly: "Weekly"
        }
    }
}

enum TimeText {
    /// "in 14 min" within the hour, else the clock time: "20:49".
    static func soon(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 * 60 { return "in \(minutes(seconds)) min" }
        return clock(date)
    }

    /// "in 3 h" within half a day, else weekday and time: "Tue 22:00".
    static func later(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 * 60 { return "in \(minutes(seconds)) min" }
        if seconds < 12 * 60 * 60 { return "in \(Int((seconds / 3600).rounded(.up))) h" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock(date))"
    }

    /// "in next 4 h" or "in next 45 min": the span until the last reset counted.
    static func span(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 * 60 { return "in next \(minutes(seconds)) min" }
        return "in next \(Int((seconds / 3600).rounded(.up))) h"
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    private static func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
