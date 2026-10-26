import Foundation

/// Limits read at a known time.
public struct DatedLimits: Sendable, Equatable {
    public var limits: [UsageLimit]
    public var date: Date

    public init(limits: [UsageLimit], date: Date) {
        self.limits = limits
        self.date = date
    }
}

/// One entry of CLIProxyAPI's `GET /v0/management/auth-files`.
public struct ProxyAuthFile: Sendable, Equatable {
    /// The auth file name, which is also the management API's key for it.
    public var name: String
    public var provider: String
    public var email: String?
    public var isDisabled: Bool
    public var weight: Int?
    /// Limits from the rate-limit headers of the account's latest real response.
    public var quota: DatedLimits?

    /// Parses the listing; logins of providers Ebb doesn't support are left out.
    public static func parseList(_ data: Data, providers: [any Provider] = Providers.all) -> [ProxyAuthFile]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = body["files"] as? [[String: Any]]
        else { return nil }
        return files.compactMap { file in
            let providerName = file["provider"] as? String ?? file["type"] as? String
            guard let name = file["name"] as? String,
                  let provider = providers.first(where: { $0.proxyName == providerName })
            else { return nil }
            let quota = file["quota"] as? [String: Any]
            let observedAt = (quota?["observed_at"] as? String).flatMap(UsageLimit.parseTimestamp)
            let limits = (quota?["signals"] as? [String: Any]).flatMap(provider.limits(fromSignals:))
            return ProxyAuthFile(
                name: name,
                provider: provider.proxyName,
                email: file["email"] as? String,
                isDisabled: file["disabled"] as? Bool ?? false,
                weight: (file["weight"] as? NSNumber)?.intValue,
                quota: limits.flatMap { limits in observedAt.map { DatedLimits(limits: limits, date: $0) } }
            )
        }
    }
}

public enum ReadingChoice {
    /// Header signals older than this describe an idle account; read its usage instead.
    public static let signalLifetime: TimeInterval = 10 * 60
    /// A usage-endpoint reading older than this is shown as stale.
    public static let usageLifetime: TimeInterval = 30 * 60

    public static func hasFreshSignals(_ signals: DatedLimits?, now: Date) -> Bool {
        signals.map { now.timeIntervalSince($0.date) < signalLifetime } ?? false
    }

    public enum Source: Sendable, Equatable {
        case proxy, usageAPI
    }

    public struct Choice: Sendable, Equatable {
        public var source: Source
        public var reading: DatedLimits
        /// Within its source's lifetime. A stale reading still counts: windows whose
        /// reset time has passed read as reset, the rest as last seen.
        public var isFresh: Bool
    }

    /// The newest reading of any age, or `nil` when the account was never read.
    public static func best(signals: DatedLimits?, usage: DatedLimits?, now: Date) -> [UsageLimit]? {
        choose(signals: signals, usage: usage, now: now)?.reading.limits
    }

    public static func choose(signals: DatedLimits?, usage: DatedLimits?, now: Date) -> Choice? {
        let candidates = [
            signals.map { Choice(source: .proxy, reading: $0, isFresh: now.timeIntervalSince($0.date) < signalLifetime) },
            usage.map { Choice(source: .usageAPI, reading: $0, isFresh: now.timeIntervalSince($0.date) < usageLifetime) },
        ]
        return candidates.compactMap { $0 }.max { $0.reading.date < $1.reading.date }
    }
}

/// An enabled login as the pool sees it.
public struct PoolMember: Sendable {
    public var plan: Plan?
    public var signals: DatedLimits?
    public var usage: DatedLimits?

    public init(plan: Plan?, signals: DatedLimits?, usage: DatedLimits?) {
        self.plan = plan
        self.signals = signals
        self.usage = usage
    }

    /// What the pool counts: `nil` when the login was never read or its plan size
    /// isn't known yet (the pool is then partial). Logins whose plan ended are left out.
    public static func poolInput(_ members: [PoolMember], now: Date) -> [AccountUsage?] {
        members.compactMap { member -> AccountUsage?? in
            if member.plan == .inactive { return .none }
            guard case let .paid(weight) = member.plan,
                  let limits = ReadingChoice.best(signals: member.signals, usage: member.usage, now: now)
            else { return .some(nil) }
            return .some(AccountUsage(weight: weight, limits: limits))
        }
    }
}

/// The weight CLIProxyAPI's weighted round robin uses to share out new threads.
public enum ProxyWeight {
    /// Changes smaller than this share aren't worth a write.
    public static let changeThreshold = 0.10

    /// Plan size times free percent: Max 20x at 4% free is 80, Team 5x at 95% free is 475.
    public static func target(planWeight: Double, freePercent: Double) -> Int {
        max(1, Int((planWeight * freePercent).rounded()))
    }

    /// Each login's share of new threads, in percent of the summed weights.
    public static func shares<Key: Hashable>(_ weights: [Key: Int]) -> [Key: Double] {
        let total = weights.values.reduce(0) { $0 + max($1, 0) }
        guard total > 0 else { return [:] }
        return weights.mapValues { Double(max($0, 0)) / Double(total) * 100 }
    }

    public static func needsUpdate(current: Int?, target: Int) -> Bool {
        guard let current, current > 0 else { return true }
        return abs(Double(target - current)) / Double(current) > changeThreshold
    }
}
