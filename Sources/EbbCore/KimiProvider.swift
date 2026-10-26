import Foundation

/// Kimi Code. `GET /coding/v1/usages` on the API host the login was made for: `api.kimi.com`
/// for `kimi`, `api.kimi.ai` for `kimi-ai` (`internal/auth/kimi/kimi.go`). Counts arrive as strings.
public struct KimiProvider: Provider {
    public init() {}

    public var proxyName: String { "kimi" }
    public var otherProxyNames: [String] { ["kimi-ai"] }
    public var title: String { "Kimi" }

    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        guard let authIndex = login.authIndex else { return nil }
        let host = login.proxyProvider == "kimi-ai" ? "api.kimi.ai" : "api.kimi.com"
        return ProxyAPICall(
            authIndex: authIndex,
            method: "GET",
            url: URL(string: "https://\(host)/coding/v1/usages")!,
            header: ["Authorization": ProxyAPICall.bearer, "Accept": "application/json", "User-Agent": "Ebb"]
        )
    }

    /// `usage` is the weekly request quota; `limits[]` holds the 300-minute window.
    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        guard let root = Signals.object(body) else { return nil }
        var limits: [UsageLimit] = []
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let window = entry["window"] as? [String: Any],
                  let duration = Signals.number(window["duration"]),
                  let detail = entry["detail"] as? [String: Any],
                  let kind = Signals.kind(windowMinutes: Self.minutes(duration, unit: window["timeUnit"] as? String)),
                  kind == .session, let limit = Self.limit(detail, kind: kind)
            else { continue }
            limits.append(limit)
            break
        }
        if let usage = root["usage"] as? [String: Any], let weekly = Self.limit(usage, kind: .weeklyAll) {
            limits.append(weekly)
        }
        let level = ((root["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
        guard !limits.isEmpty || level != nil else { return nil }
        return UsageCallReading(limits: limits.isEmpty ? nil : limits, planName: level?.lowercased())
    }

    /// `{limit, used, resetTime}`; `remaining` stands in for `used` when that's missing.
    private static func limit(_ detail: [String: Any], kind: UsageLimit.Kind) -> UsageLimit? {
        guard let total = Signals.number(detail["limit"]), total > 0 else { return nil }
        let used = Signals.number(detail["used"]) ?? Signals.number(detail["remaining"]).map { total - $0 }
        guard let used else { return nil }
        let reset = [detail["resetTime"], detail["reset_time"], detail["resetAt"]].lazy.compactMap(Self.timestamp).first
        return UsageLimit(kind: kind, usedPercent: Signals.percent(used / total * 100), resetsAt: reset)
    }

    /// Kimi sends nanoseconds ("…02.717479433Z"), more digits than ISO 8601 parsing takes.
    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return Signals.date(value) }
        let trimmed = text.replacing(/\.(\d{3})\d+/) { ".\($0.1)" }
        return UsageLimit.parseTimestamp(trimmed)
    }

    private static func minutes(_ duration: Double, unit: String?) -> Double {
        switch unit?.uppercased() {
        case "TIME_UNIT_SECOND": duration / 60
        case "TIME_UNIT_HOUR": duration * 60
        case "TIME_UNIT_DAY": duration * 24 * 60
        default: duration
        }
    }
}
