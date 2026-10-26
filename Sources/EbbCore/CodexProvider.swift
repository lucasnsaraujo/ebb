import Foundation

/// ChatGPT subscriptions used through Codex. CLIProxyAPI keeps the `x-codex-*` headers of
/// each login's latest response (`internal/runtime/executor/helps/codex_quota.go`); an idle
/// login is read from `GET chatgpt.com/backend-api/wham/usage`, the endpoint Codex itself uses.
public struct CodexProvider: Provider {
    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public var proxyName: String { "codex" }
    public var title: String { "Codex" }

    /// `X-Codex-Primary-*` and `-Secondary-*`. The window's length, not its slot, says which
    /// pool window it is: plans without a 5-hour cap send the weekly window as the primary one.
    /// Model-specific limits (`X-Codex-<name>-Primary-*`) are left out, like Claude's.
    public func limits(fromSignals signals: [String: Any], observedAt: Date) -> [UsageLimit]? {
        let values = Signals.lowercased(signals)
        let windows = ["primary", "secondary"].compactMap { slot -> Window? in
            let prefix = "x-codex-\(slot)-"
            guard let used = values[prefix + "used-percent"].flatMap(Double.init),
                  let minutes = values[prefix + "window-minutes"].flatMap(Double.init)
            else { return nil }
            let reset = values[prefix + "reset-at"].flatMap(Signals.date)
                ?? values[prefix + "reset-after-seconds"].flatMap(Double.init).map { observedAt + $0 }
            return Window(used: used, minutes: minutes, reset: reset)
        }
        let isBlocked = values["x-codex-limit-reached"] == "true" || values["x-codex-allowed"] == "false"
        return Self.limits(windows, isBlocked: isBlocked)
    }

    /// The live `X-Codex-Plan-Type`, else the `chatgpt_plan_type` claim of the login's ID token.
    public func planName(fromEntry entry: [String: Any]) -> String? {
        let signals = ((entry["quota"] as? [String: Any])?["signals"] as? [String: Any]).map(Signals.lowercased)
        let plan = signals?["x-codex-plan-type"] ?? (entry["id_token"] as? [String: Any])?["plan_type"] as? String
        return plan.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        guard let authIndex = login.authIndex else { return nil }
        var header = ["Authorization": ProxyAPICall.bearer, "Accept": "application/json", "User-Agent": "Ebb"]
        if let account = login.accountID { header["ChatGPT-Account-Id"] = account }
        return ProxyAPICall(authIndex: authIndex, method: "GET", url: Self.usageEndpoint, header: header)
    }

    /// `rate_limit.primary_window` / `.secondary_window`: `{used_percent, limit_window_seconds, reset_at}`.
    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        guard let root = Signals.object(body) else { return nil }
        let plan = (root["plan_type"] as? String)?.lowercased()
        guard let rateLimit = root["rate_limit"] as? [String: Any] else {
            return plan.map { UsageCallReading(limits: nil, planName: $0) }
        }
        let windows = ["primary_window", "secondary_window"].compactMap { key -> Window? in
            guard let window = rateLimit[key] as? [String: Any],
                  let used = Signals.number(window["used_percent"]),
                  let seconds = Signals.number(window["limit_window_seconds"])
            else { return nil }
            return Window(used: used, minutes: seconds / 60, reset: Signals.date(window["reset_at"]))
        }
        let isBlocked = rateLimit["limit_reached"] as? Bool == true || rateLimit["allowed"] as? Bool == false
        return UsageCallReading(limits: Self.limits(windows, isBlocked: isBlocked), planName: plan)
    }

    private struct Window {
        var used: Double
        var minutes: Double
        var reset: Date?
    }

    /// A blocked login reads as fully used on its fullest window, whatever the percent says.
    private static func limits(_ windows: [Window], isBlocked: Bool) -> [UsageLimit]? {
        var limits = windows.compactMap { window in
            Signals.kind(windowMinutes: window.minutes).map {
                UsageLimit(kind: $0, usedPercent: Signals.percent(window.used), resetsAt: window.reset)
            }
        }
        guard !limits.isEmpty else { return nil }
        if isBlocked, let fullest = limits.indices.max(by: { limits[$0].usedPercent < limits[$1].usedPercent }) {
            limits[fullest].usedPercent = 100
        }
        return limits.sorted { $0.kind == .session && $1.kind != .session }
    }
}
