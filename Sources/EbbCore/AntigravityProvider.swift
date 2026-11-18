import Foundation

/// Google Antigravity. Read from `fetchAvailableModels`, which gives each model a 5-hour window
/// as a *remaining* fraction. `retrieveUserQuotaSummary`, with model groups and a weekly bucket,
/// answers 403 "Verify your account" for consumer logins, so its shape is only still understood.
public struct AntigravityProvider: Provider {
    static let modelsEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    /// Google refuses the model list to any other client.
    static let userAgent = "antigravity/1.15.8 darwin/arm64"
    /// The models the pool is used for; the rest of their family shares these windows or doesn't matter.
    static let headlineModels: Set = ["claude-opus-4-6-thinking", "gemini-3-flash", "gemini-3.8-flash-tiered"]

    public init() {}

    public var proxyName: String { "antigravity" }
    public var title: String { "Antigravity" }

    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        guard let authIndex = login.authIndex else { return nil }
        let body: [String: String] = login.projectID.map { ["project": $0] } ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        return ProxyAPICall(
            authIndex: authIndex,
            method: "POST",
            url: Self.modelsEndpoint,
            header: ["Authorization": ProxyAPICall.bearer, "Content-Type": "application/json", "User-Agent": Self.userAgent],
            data: data ?? "{}"
        )
    }

    /// Each window takes its tightest group: an account is out of 5-hour capacity once
    /// either model family is. Disabled buckets, and buckets with neither a fraction nor a reset, are skipped.
    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        guard let root = Signals.object(body) else { return nil }
        if let models = root["models"] as? [String: Any] { return Self.readModels(models) }
        let payload = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
        guard let groups = payload["groups"] as? [[String: Any]] else { return nil }
        var tightest: [UsageLimit.Kind: UsageLimit] = [:]
        for bucket in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) where bucket["disabled"] as? Bool != true {
            guard let kind = Self.kind(of: bucket), let remaining = Self.remainingFraction(bucket) else { continue }
            let limit = UsageLimit(kind: kind, usedPercent: Signals.percent((1 - remaining) * 100), resetsAt: Signals.date(bucket["resetTime"]))
            if (tightest[kind]?.usedPercent ?? -1) < limit.usedPercent { tightest[kind] = limit }
        }
        let limits = [tightest[.session], tightest[.weeklyAll]].compactMap { $0 }
        return UsageCallReading(limits: limits.isEmpty ? nil : limits, planName: nil)
    }

    /// The model families with quotas of their own, by id prefix.
    static let families = ["claude-", "gemini-"]

    /// The 5-hour window of the tightest model the pool is used for: a spent family leaves the
    /// account out of that capacity. Each family is read from its headline models, or from all its
    /// models once a new lineup renames them; with no family at all, from any model with a window.
    private static func readModels(_ models: [String: Any]) -> UsageCallReading {
        let windows = models.compactMapValues { model -> UsageLimit? in
            guard let quota = (model as? [String: Any])?["quotaInfo"] as? [String: Any],
                  let resetsAt = Signals.date(quota["resetTime"])
            else { return nil }
            let remaining = Signals.number(quota["remainingFraction"]).map { min(max($0, 0), 1) } ?? 0
            return UsageLimit(kind: .session, usedPercent: Signals.percent((1 - remaining) * 100), resetsAt: resetsAt)
        }
        let counted = families.flatMap { family in
            let members = windows.filter { $0.key.hasPrefix(family) }
            let headline = members.filter { headlineModels.contains($0.key) }
            return Array((headline.isEmpty ? members : headline).values)
        }
        // Ties go to the sooner reset, so the answer doesn't follow the dictionary's order.
        let tightest = (counted.isEmpty ? Array(windows.values) : counted).max {
            ($0.usedPercent, $1.resetsAt ?? .distantFuture) < ($1.usedPercent, $0.resetsAt ?? .distantFuture)
        }
        return UsageCallReading(limits: tightest.map { [$0] }, planName: nil)
    }

    /// The bucket's `window`, else its id or name ("gemini-5h", "claude-gpt-weekly").
    private static func kind(of bucket: [String: Any]) -> UsageLimit.Kind? {
        let names = [bucket["window"], bucket["bucketId"], bucket["displayName"]].compactMap { ($0 as? String)?.lowercased() }
        guard let name = names.first(where: { !$0.isEmpty }) else { return nil }
        if ["5h", "session", "5-hour", "five-hour"].contains(where: name.contains) { return .session }
        if name.contains("weekly") { return .weeklyAll }
        return nil
    }

    /// Google's JSON leaves out fields at zero, so a bucket with a reset but no fraction is spent.
    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        let nested = (bucket["remaining"] as? [String: Any])?["remainingFraction"]
        if let fraction = Signals.number(bucket["remainingFraction"]) ?? Signals.number(nested) { return min(max(fraction, 0), 1) }
        return Signals.date(bucket["resetTime"]) == nil ? nil : 0
    }
}
