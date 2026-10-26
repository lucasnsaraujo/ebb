import Foundation

/// Meta Muse Code. Its plan and windows come back from `POST api.meta.ai/muse-code/key`,
/// which only accepts the device-code (`dca:`) login token. CLIProxyAPI's `$TOKEN$` resolves
/// Meta logins to the minted key instead (`metaTokenFromAuth` skips `dca:` tokens), so expect
/// "Limits not available" until the proxy can send the device token.
public struct MetaProvider: Provider {
    static let keyEndpoint = URL(string: "https://api.meta.ai/muse-code/key")!

    public init() {}

    public var proxyName: String { "meta" }
    public var title: String { "Muse" }

    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? {
        guard let authIndex = login.authIndex else { return nil }
        return ProxyAPICall(
            authIndex: authIndex,
            method: "POST",
            url: Self.keyEndpoint,
            header: [
                "Authorization": ProxyAPICall.bearer, "Content-Type": "application/json",
                "x-api-version": "1.0.0", "User-Agent": "Ebb",
            ],
            data: "{}"
        )
    }

    /// `subs_usage.window` (5-hour, `window_duration_mins`) and `.weekly`, `used_percent` with
    /// unix `resets_at`. `is_subs_active: false` is a definitive "no subscription".
    public func readUsageCall(_ body: Data) -> UsageCallReading? {
        guard let root = Signals.object(body), let isActive = root["is_subs_active"] as? Bool else { return nil }
        let plan = (root["subs_tier_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard isActive else { return UsageCallReading(limits: nil, planName: plan, hasEndedSubscription: true) }
        let usage = root["subs_usage"] as? [String: Any]
        func window(_ key: String, kind: UsageLimit.Kind) -> UsageLimit? {
            guard let window = usage?[key] as? [String: Any], let used = Signals.number(window["used_percent"]) else { return nil }
            return UsageLimit(kind: kind, usedPercent: Signals.percent(used), resetsAt: Signals.date(window["resets_at"]))
        }
        let limits = [window("window", kind: .session), window("weekly", kind: .weeklyAll)].compactMap { $0 }
        return UsageCallReading(limits: limits.isEmpty ? nil : limits, planName: plan)
    }
}
