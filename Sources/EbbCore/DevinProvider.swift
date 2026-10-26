import Foundation

/// Devin seats. CLIProxyAPI writes the quota from Devin's `GetUserStatus` into the login's
/// signals at login and on each token refresh (`internal/auth/devin/record.go`,
/// `internal/runtime/executor/devin_executor.go`), as remaining percents like "73%".
public struct DevinProvider: Provider {
    public init() {}

    public var proxyName: String { "devin" }
    public var title: String { "Devin" }
    public var shortWindow: ShortWindow { .day }

    public func limits(fromSignals signals: [String: Any], observedAt: Date) -> [UsageLimit]? {
        let values = Signals.lowercased(signals)
        func window(_ name: String, kind: UsageLimit.Kind) -> UsageLimit? {
            guard let text = values["\(name)_quota_remaining_percent"],
                  let remaining = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
            else { return nil }
            let reset = values["\(name)_quota_reset_at"].flatMap(UsageLimit.parseTimestamp)
            return UsageLimit(kind: kind, usedPercent: Signals.percent(100 - remaining), resetsAt: reset)
        }
        let limits = [window("daily", kind: .session), window("weekly", kind: .weeklyAll)].compactMap { $0 }
        return limits.isEmpty ? nil : limits
    }

    public func planName(fromEntry entry: [String: Any]) -> String? {
        let signals = ((entry["quota"] as? [String: Any])?["signals"] as? [String: Any]).map(Signals.lowercased)
        return signals?["plan"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }
}
