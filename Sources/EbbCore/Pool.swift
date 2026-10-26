import Foundation

/// What one account contributes to the pool: its plan weight and its latest limits.
public struct AccountUsage: Sendable, Equatable {
    public var weight: Double
    public var limits: [UsageLimit]

    public init(weight: Double, limits: [UsageLimit]) {
        self.weight = weight
        self.limits = limits
    }
}

/// Capacity that comes back to a window at `date`, in pool percentage points.
public struct Restoration: Sendable, Equatable {
    public var date: Date
    public var gain: Double

    public init(date: Date, gain: Double) {
        self.date = date
        self.gain = gain
    }
}

public enum PoolWindow: Sendable, Equatable {
    case session, weekly
}

/// One window of the pool, never mixed with the other: a share of the 5-hour
/// bucket and a share of the weekly bucket are different units.
public struct WindowSummary: Sendable, Equatable {
    /// Weighted share of this window still free, 0–100.
    public var freePercent: Double
    /// Upcoming resets of this window, soonest first.
    public var resets: [Restoration]
}

public struct PoolSummary: Sendable, Equatable {
    public var session: WindowSummary
    /// Accounts without a weekly cap count as fully free.
    public var weekly: WindowSummary
    /// True when some account has no usable reading and is left out of the totals.
    public var isPartial: Bool
}

/// What the menu bar item shows: always the 5-hour window, plus a warning
/// badge when the weekly window is nearly gone, so a weekly lock-out isn't a surprise.
public struct MenuBarReading: Sendable, Equatable {
    public static let weeklyWarningBelow = 10.0

    public var sessionPercent: Int
    public var isWeeklyLow: Bool

    public init(sessionPercent: Int, isWeeklyLow: Bool) {
        self.sessionPercent = sessionPercent
        self.isWeeklyLow = isWeeklyLow
    }

    public init(_ summary: PoolSummary) {
        sessionPercent = Int(summary.session.freePercent.rounded())
        isWeeklyLow = summary.weekly.freePercent < Self.weeklyWarningBelow
    }
}

public enum Pool {
    /// Resets this close together read as one event.
    public static let mergeWindow: TimeInterval = 5 * 60
    /// The session window's length; its resets all fall within it.
    public static let sessionHorizon: TimeInterval = 5 * 60 * 60

    /// Summarizes the pool. `nil` entries are accounts without a usable reading.
    public static func summarize(_ accounts: [AccountUsage?], at now: Date) -> PoolSummary? {
        let readable = accounts.compactMap { $0 }.filter { $0.weight > 0 }
        let totalWeight = readable.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        func window(_ kind: UsageLimit.Kind, horizon: TimeInterval?) -> WindowSummary {
            var free = 0.0
            var resets: [Restoration] = []
            for account in readable {
                let limit = account.limits.first { $0.kind == kind }
                let used = limit?.used(at: now) ?? 0
                free += account.weight * (100 - used)
                if let date = limit?.resetsAt, date > now, used > 0, horizon.map({ date.timeIntervalSince(now) <= $0 }) ?? true {
                    resets.append(Restoration(date: date, gain: account.weight * used / totalWeight))
                }
            }
            return WindowSummary(freePercent: free / totalWeight, resets: merge(resets))
        }

        return PoolSummary(
            session: window(.session, horizon: sessionHorizon),
            weekly: window(.weeklyAll, horizon: nil),
            isPartial: accounts.contains(nil)
        )
    }

    /// An account can only spend what its tightest general window allows.
    /// Used to steer the proxy, never shown as a pool number.
    public static func effectiveFree(_ limits: [UsageLimit], at now: Date) -> Double {
        let used = limits.filter { $0.kind == .session || $0.kind == .weeklyAll }.map { $0.used(at: now) }
        return 100 - (used.max() ?? 0)
    }

    /// Folds events within `mergeWindow` of a group's first event into it,
    /// dated at its last event, when the whole gain is back.
    private static func merge(_ events: [Restoration]) -> [Restoration] {
        var merged: [(start: Date, event: Restoration)] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            if let last = merged.last, event.date.timeIntervalSince(last.start) <= mergeWindow {
                merged[merged.count - 1].event = Restoration(date: event.date, gain: last.event.gain + event.gain)
            } else {
                merged.append((event.date, event))
            }
        }
        return merged.map(\.event)
    }
}
