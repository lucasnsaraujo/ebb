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
public struct Restoration: Sendable, Equatable, Codable {
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
    /// The part of `freePercent` that can't be used up: accounts with no cap on this window.
    public var uncappedPercent = 0.0
}

public struct PoolSummary: Sendable, Equatable {
    public var session: WindowSummary
    /// Accounts without a weekly cap count as fully free.
    public var weekly: WindowSummary
    /// True when some account has no usable reading and is left out of the totals.
    public var isPartial: Bool
    /// Summed plan weight of the accounts read: weighted demand divided by it gives pool points.
    public var totalWeight = 0.0
    /// Share of the accounts that could be read, 0–1.
    public var readableShare = 1.0
}

public enum Pool {
    /// Resets this close together read as one event.
    public static let mergeWindow: TimeInterval = 5 * 60
    /// The session window's length; its resets all fall within it.
    public static let sessionHorizon: TimeInterval = 5 * 60 * 60

    /// Summarizes the pool. `nil` entries are accounts without a usable reading.
    /// `sessionHorizon` bounds the short window's resets: five hours, or a day for Devin.
    public static func summarize(_ accounts: [AccountUsage?], at now: Date, sessionHorizon: TimeInterval = sessionHorizon) -> PoolSummary? {
        let readable = accounts.compactMap { $0 }.filter { $0.weight > 0 }
        let totalWeight = readable.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        func window(_ kind: UsageLimit.Kind, horizon: TimeInterval?) -> WindowSummary {
            var free = 0.0
            var uncapped = 0.0
            var resets: [Restoration] = []
            for account in readable {
                let limit = account.limits.first { $0.kind == kind }
                let used = limit?.used(at: now) ?? 0
                free += account.weight * (100 - used)
                if limit == nil, kind == .weeklyAll { uncapped += account.weight * 100 }
                if let date = limit?.resetsAt, date > now, used > 0, horizon.map({ date.timeIntervalSince(now) <= $0 }) ?? true {
                    resets.append(Restoration(date: date, gain: account.weight * used / totalWeight))
                }
            }
            return WindowSummary(freePercent: free / totalWeight, resets: merge(resets), uncappedPercent: uncapped / totalWeight)
        }

        return PoolSummary(
            session: window(.session, horizon: sessionHorizon),
            weekly: window(.weeklyAll, horizon: nil),
            isPartial: accounts.contains(nil),
            totalWeight: totalWeight,
            readableShare: Double(readable.count) / Double(accounts.count)
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

/// A login as the pools see it: the provider it belongs to, and its pool member,
/// or `nil` for a login whose provider only reports health.
public struct ProviderLogin: Sendable {
    public var provider: String
    public var member: PoolMember?

    public init(provider: String, member: PoolMember?) {
        self.provider = provider
        self.member = member
    }
}

/// One pool per provider. A Claude 5-hour share and a Codex 5-hour share are different
/// allowances, so capacity is never blended across providers.
public enum ProviderPools {
    /// Summaries by provider name; health-only logins never count.
    public static func summarize(_ logins: [ProviderLogin], at now: Date) -> [String: PoolSummary] {
        var members: [String: [PoolMember]] = [:]
        for login in logins {
            guard let member = login.member, Providers.named(login.provider) != nil else { continue }
            members[login.provider, default: []].append(member)
        }
        var summaries: [String: PoolSummary] = [:]
        for (name, group) in members {
            let horizon = Providers.named(name)?.shortWindow.horizon ?? Pool.sessionHorizon
            summaries[name] = Pool.summarize(PoolMember.poolInput(group, now: now), at: now, sessionHorizon: horizon)
        }
        return summaries
    }

    /// Each provider's pooled plan weight: paying, enabled logins only.
    public static func pooledWeight(_ logins: [ProviderLogin]) -> [String: Double] {
        var weights: [String: Double] = [:]
        for login in logins {
            guard let plan = login.member?.plan, Providers.named(login.provider) != nil else { continue }
            weights[login.provider, default: 0] += plan.weight
        }
        return weights
    }

    /// The provider the menu bar shows by default: the one with the most pooled weight,
    /// ties going to the earlier one in `Providers.all`.
    public static func defaultProvider(_ weights: [String: Double]) -> String? {
        let order = Providers.all.map(\.proxyName)
        return weights
            .filter { $0.value > 0 }
            .max { lhs, rhs in
                lhs.value == rhs.value
                    ? (order.firstIndex(of: lhs.key) ?? .max) > (order.firstIndex(of: rhs.key) ?? .max)
                    : lhs.value < rhs.value
            }?
            .key
    }
}
