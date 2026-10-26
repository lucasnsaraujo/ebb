import Foundation

/// Google Antigravity. Read from `retrieveUserQuotaSummary`, which groups Gemini models and
/// Claude + GPT models, each with a 5-hour and a weekly bucket of *remaining* fractions.
public struct AntigravityProvider: Provider {
    static let summaryEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!

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
            url: Self.summaryEndpoint,
            header: ["Authorization": ProxyAPICall.bearer, "Content-Type": "application/json", "User-Agent": "Ebb"],
            data: data ?? "{}"
        )
    }

    /// Each window takes its tightest group: an account is out of 5-hour capacity once
    /// either model family is. Disabled buckets, and buckets with neither a fraction nor a reset, are skipped.
    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        guard let root = Signals.object(body) else { return nil }
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
