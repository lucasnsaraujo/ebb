import Foundation

/// Claude subscriptions, through the OAuth endpoints Claude Code itself uses.
/// Reading usage or the profile spends no quota.
public struct ClaudeProvider: Provider {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let signalPrefix = "anthropic-ratelimit-unified-"

    public init() {}

    public var proxyName: String { "claude" }
    public var title: String { "Claude" }

    public func usageRequest(accessToken: String) -> URLRequest {
        request(Self.usageEndpoint, accessToken: accessToken)
    }

    public func planRequest(accessToken: String) -> URLRequest {
        request(Self.profileEndpoint, accessToken: accessToken)
    }

    /// The `limits` array of `GET /api/oauth/usage`.
    public func parseUsage(_ data: Data) -> [UsageLimit]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLimits = body["limits"] as? [Any],
              let limitsData = try? JSONSerialization.data(withJSONObject: rawLimits)
        else { return nil }
        return try? UsageLimit.decodeList(from: limitsData)
    }

    /// `organization.rate_limit_tier` and `organization.subscription_status` of `GET /api/oauth/profile`.
    public func parsePlan(_ data: Data) -> PlanProfile? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = body["organization"] as? [String: Any],
              organization.keys.contains("subscription_status"),
              organization.keys.contains("rate_limit_tier")
        else { return nil }
        let tier = organization["rate_limit_tier"] as? String
        return PlanProfile(plan: Self.plan(rateLimitTier: tier, subscriptionStatus: organization["subscription_status"] as? String), tier: tier)
    }

    /// The tier without its prefix: "max_20x", "max_5x", "pro"; the key for weight overrides.
    public static func planName(rateLimitTier: String?) -> String? {
        guard let tier = rateLimitTier?.lowercased(), !tier.isEmpty else { return nil }
        return tier.hasPrefix("default_claude_") ? String(tier.dropFirst("default_claude_".count)) : tier
    }

    /// Statuses that say the plan is over. Only these count as inactive, since an inactive
    /// plan gets the login disabled in the proxy; a status Ebb doesn't know, a grace period
    /// (`past_due`) or a missing value keeps the tier's weight.
    static let endedStatuses: Set<String> = ["canceled", "cancelled", "expired", "incomplete_expired", "inactive", "ended"]

    /// The tier's default weight from `PlanWeights`: "default_claude_max_20x" weighs 20 a session
    /// and 7 a week, a paid tier without a multiplier (Pro) 1. A subscription whose status says it ended is inactive.
    public static func plan(rateLimitTier: String?, subscriptionStatus: String?) -> Plan {
        if let status = subscriptionStatus?.lowercased(), endedStatuses.contains(status) { return .inactive }
        guard let tier = rateLimitTier?.lowercased(), !tier.isEmpty, !tier.contains("free"),
              let weight = PlanWeights.defaultWeight(provider: ClaudeProvider().proxyName, plan: planName(rateLimitTier: tier))
        else { return .unknown }
        return .paid(weight: weight)
    }

    /// The per-session multiplier a tier's name carries: 20 for "max_20x"; `nil` without one.
    static func multiplier(rateLimitTier tier: String) -> Double? {
        guard let match = tier.firstMatch(of: /_(\d+)x$/), let multiplier = Double(match.1), multiplier > 0 else { return nil }
        return multiplier
    }

    public func limits(fromSignals signals: [String: Any], observedAt: Date) -> [UsageLimit]? {
        limits(fromSignals: signals)
    }

    /// `anthropic-ratelimit-unified-overage-status`: `allowed` or `allowed_warning` while extra
    /// usage is on; `rejected`, with a disabled reason, when it's off or spent.
    public func extraUsage(fromSignals signals: [String: Any]) -> ExtraUsage? {
        switch Signals.lowercased(signals)["anthropic-ratelimit-unified-overage-status"] {
        case "allowed": .claudeOverage(isNearLimit: false)
        case "allowed_warning": .claudeOverage(isNearLimit: true)
        default: nil
        }
    }

    /// The same two requests through the proxy, for a proxy on another machine whose auth
    /// folder is out of reach. The headers match the direct requests; the proxy fills in the token.
    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        call(Self.usageEndpoint, for: login)
    }

    public func planCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        call(Self.profileEndpoint, for: login)
    }

    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        parseUsage(body).map { UsageCallReading(limits: $0, planName: nil) }
    }

    /// The profile as a reading: the tier's plan name, and whether the subscription ended.
    public func readPlanCall(_ body: Data) -> UsageCallReading? {
        guard let profile = parsePlan(body) else { return nil }
        return UsageCallReading(limits: nil, planName: Self.planName(rateLimitTier: profile.tier), hasEndedSubscription: profile.plan == .inactive)
    }

    private func call(_ url: URL, for login: ProxyAuthFile) -> ProxyAPICall? {
        guard let authIndex = login.authIndex else { return nil }
        var request = request(url, accessToken: ProxyAPICall.tokenPlaceholder)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return ProxyAPICall(authIndex: authIndex, method: "GET", url: url, header: request.allHTTPHeaderFields ?? [:])
    }

    /// `Anthropic-Ratelimit-Unified-5h-*` and `-7d-*`. `nil` without a 5-hour utilization, the one
    /// window every plan has. `7d` is the general weekly window; `7d_oi` and per-model caps are ignored.
    public func limits(fromSignals signals: [String: Any]) -> [UsageLimit]? {
        let values = Signals.lowercased(signals)

        func window(_ name: String, kind: UsageLimit.Kind) -> UsageLimit? {
            guard let utilization = values[Self.signalPrefix + name + "-utilization"].flatMap(Double.init) else { return nil }
            let reset = values[Self.signalPrefix + name + "-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            let percent = (utilization * 100 * 100).rounded() / 100
            return UsageLimit(kind: kind, usedPercent: percent, resetsAt: reset)
        }

        guard let session = window("5h", kind: .session) else { return nil }
        return [session] + [window("7d", kind: .weeklyAll)].compactMap { $0 }
    }

    private func request(_ url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Ebb", forHTTPHeaderField: "User-Agent")
        return request
    }
}
