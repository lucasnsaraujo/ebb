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

/// A login's health as the proxy sees it: every provider has this, usage windows or not.
public struct AccountHealth: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case ok
        /// The proxy is holding it back until `until`, after errors or a spent quota.
        case coolingDown(until: Date?)
        case failing
        case disabled
    }

    public var state: State
    /// The proxy's own words, such as "quota exhausted".
    public var message: String?
    public var successes: Int
    public var failures: Int

    public init(state: State, message: String? = nil, successes: Int = 0, failures: Int = 0) {
        self.state = state
        self.message = message
        self.successes = successes
        self.failures = failures
    }

    /// `disabled`, `unavailable` with `next_retry_after`, and `status: "error"` from the listing.
    static func read(_ file: [String: Any]) -> AccountHealth {
        let message = (file["status_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let retry = (file["next_retry_after"] as? String).flatMap(UsageLimit.parseTimestamp)
        let state: State = if file["disabled"] as? Bool == true || file["status"] as? String == "disabled" {
            .disabled
        } else if file["unavailable"] as? Bool == true || retry != nil {
            .coolingDown(until: retry)
        } else if file["status"] as? String == "error" {
            .failing
        } else {
            .ok
        }
        return AccountHealth(
            state: state,
            message: message,
            successes: (file["success"] as? NSNumber)?.intValue ?? 0,
            failures: (file["failed"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// One entry of CLIProxyAPI's `GET /v0/management/auth-files`.
public struct ProxyAuthFile: Sendable, Equatable {
    /// The auth file name, which is also the management API's key for it.
    public var name: String
    /// Ebb's name for the provider: the supported provider's `proxyName`, else the proxy's own.
    public var provider: String
    /// The proxy's name for it, which can differ (`kimi-ai`).
    public var proxyProvider: String
    /// The key `api-call` takes to act as this login.
    public var authIndex: String?
    public var email: String?
    public var label: String?
    public var isDisabled: Bool
    public var weight: Int?
    /// Limits from the quota signals of the account's latest real response.
    public var quota: DatedLimits?
    /// The plan named in the listing (Codex ID token, Devin signals).
    public var planName: String?
    /// Codex's `chatgpt_account_id`, sent along with usage reads.
    public var accountID: String?
    /// Google Cloud project, needed for Antigravity's quota summary.
    public var projectID: String?
    public var health: AccountHealth
    /// From the latest response's signals; never part of a pool's numbers. Read it through `extraUsage(at:)`.
    public var extraUsage: ExtraUsage?
    /// When the proxy saw the response those signals came from.
    public var signalsObservedAt: Date?

    /// Signals older than a day may predate a change to the account's billing, so they say nothing.
    public static let extraUsageLifetime: TimeInterval = 24 * 60 * 60

    public func extraUsage(at now: Date) -> ExtraUsage? {
        guard let signalsObservedAt, now.timeIntervalSince(signalsObservedAt) < Self.extraUsageLifetime else { return nil }
        return extraUsage
    }

    /// Logins of providers with usage windows count toward a pool; the rest show health only.
    public var hasUsageWindows: Bool {
        Providers.named(provider) != nil
    }

    /// Email, else the label, else the file name.
    public var displayName: String {
        email ?? label ?? name
    }

    /// Whether Ebb reads this login through the proxy's listing and `api-call`: every provider
    /// but Claude, whose auth files Ebb reads itself unless the proxy is on another machine.
    public func isReadThroughProxy(isRemote: Bool) -> Bool {
        provider != ClaudeProvider().proxyName || isRemote
    }

    /// Parses the listing, every provider included.
    public static func parseList(_ data: Data) -> [ProxyAuthFile]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = body["files"] as? [[String: Any]]
        else { return nil }
        return files.compactMap { file in
            guard let name = file["name"] as? String,
                  let proxyProvider = (file["provider"] as? String ?? file["type"] as? String)?.lowercased()
            else { return nil }
            let provider = Providers.named(proxyProvider)
            let quota = file["quota"] as? [String: Any]
            let observedAt = (quota?["observed_at"] as? String).flatMap(UsageLimit.parseTimestamp)
            let limits = observedAt.flatMap { date in
                (quota?["signals"] as? [String: Any]).flatMap { provider?.limits(fromSignals: $0, observedAt: date) }
            }
            let idToken = file["id_token"] as? [String: Any]
            return ProxyAuthFile(
                name: name,
                provider: provider?.proxyName ?? proxyProvider,
                proxyProvider: proxyProvider,
                authIndex: (file["auth_index"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                email: (file["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                label: (file["label"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isDisabled: file["disabled"] as? Bool ?? false,
                weight: (file["weight"] as? NSNumber)?.intValue,
                quota: limits.flatMap { limits in observedAt.map { DatedLimits(limits: limits, date: $0) } },
                planName: provider?.planName(fromEntry: file),
                accountID: idToken?["chatgpt_account_id"] as? String,
                projectID: (file["project_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                health: AccountHealth.read(file),
                extraUsage: (quota?["signals"] as? [String: Any]).flatMap { provider?.extraUsage(fromSignals: $0) },
                signalsObservedAt: observedAt
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
                  let reading = ReadingChoice.choose(signals: member.signals, usage: member.usage, now: now)?.reading
            else { return .some(nil) }
            return .some(AccountUsage(weight: weight, limits: reading.limits, readAt: reading.date))
        }
    }
}

/// The weight CLIProxyAPI's weighted round robin uses to share out new threads.
public enum ProxyWeight {
    /// Changes smaller than this share aren't worth a write.
    public static let changeThreshold = 0.10

    /// Plan size times free percent times reset urgency: Max 20x at 4% free is 80, Team 5x at
    /// 95% free is 475, and 713 a day before its weekly reset.
    public static func target(planWeight: Double, freePercent: Double, urgency: Double = 1) -> Int {
        max(1, Int((planWeight * freePercent * urgency).rounded()))
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

/// Favors free weekly capacity that's about to expire: what a login hasn't used by its weekly
/// reset is lost, so in the week's last two days its weight rises steadily, up to double at the
/// reset. cliproxy-rs's `soonest-reset` strategy spends the soonest-resetting account outright;
/// a bounded factor keeps the even drain, so no single login runs into its 5-hour limit.
public enum ResetUrgency {
    /// Urgency starts this long before the weekly reset.
    public static let horizon: TimeInterval = 48 * 60 * 60
    public static let maximum = 2.0

    /// 1 with no weekly reset ahead or more than `horizon` away, rising linearly to `maximum` at the reset.
    public static func factor(weeklyResetsAt: Date?, now: Date) -> Double {
        guard let weeklyResetsAt else { return 1 }
        let left = weeklyResetsAt.timeIntervalSince(now)
        guard left > 0, left < horizon else { return 1 }
        return 1 + (maximum - 1) * (1 - left / horizon)
    }

    /// The weekly window's reset, for `factor`.
    public static func weeklyReset(in limits: [UsageLimit]) -> Date? {
        limits.first { $0.kind == .weeklyAll }?.resetsAt
    }
}

/// A login's reset urgency, for the Settings → Routing explanation.
public struct UrgentLogin: Sendable, Equatable {
    /// Below this the boost would read as "×1.0".
    public static let shownFactor = 1.05

    public var provider: String
    public var freePercent: Double
    public var factor: Double
    public var weeklyResetsAt: Date?

    public init(provider: String, freePercent: Double, factor: Double, weeklyResetsAt: Date?) {
        self.provider = provider
        self.freePercent = freePercent
        self.factor = factor
        self.weeklyResetsAt = weeklyResetsAt
    }

    /// The highest boost worth naming: on a login with room left, whose provider has another
    /// login to weigh it against, since the proxy only balances logins of one provider.
    public static func strongest(_ logins: [UrgentLogin]) -> UrgentLogin? {
        let counts = Dictionary(logins.map { ($0.provider, 1) }, uniquingKeysWith: +)
        return logins
            .filter { $0.factor >= shownFactor && $0.freePercent > 0 && $0.weeklyResetsAt != nil && counts[$0.provider, default: 0] > 1 }
            .max { $0.factor < $1.factor }
    }

    /// "Now ×1.7 for a Codex login whose week resets in 13h."
    public func explanation(now: Date) -> String {
        let factorText = factor.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
        let left = weeklyResetsAt.map { RefillText.until($0, now: now) } ?? "?"
        return "Now ×\(factorText) for a \(provider) login whose week resets in \(left)."
    }
}
