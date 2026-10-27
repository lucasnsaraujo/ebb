import Foundation

/// The proxy still holds a login in cooldown while a fresh reading shows it has quota again
/// (CLIProxyAPI #5404, #5770): new sessions skip capacity that's really there. Ebb only points
/// it out; clearing it is the proxy's `reset-quota` call, which the user runs.
public enum StuckCooldown {
    /// Backoffs shorter than this clear on their own soon enough.
    public static let minimumHold: TimeInterval = 15 * 60
    /// A reading older than this can't say the quota came back.
    public static let readingLifetime: TimeInterval = ReadingChoice.usageLifetime

    /// `usage` must be a usage-endpoint reading taken after `signalsObservedAt`, the proxy's last
    /// response: that response may be the 429 that started the cooldown, from a window Ebb doesn't count.
    /// A hold with no end is a login the provider rejected, which `reset-quota` can't clear.
    public static func isStuck(health: AccountHealth, usage: DatedLimits?, signalsObservedAt: Date?, now: Date) -> Bool {
        guard case let .coolingDown(until?) = health.state, until.timeIntervalSince(now) >= minimumHold,
              let usage, now.timeIntervalSince(usage.date) <= readingLifetime,
              signalsObservedAt.map({ usage.date > $0 }) ?? true
        else { return false }
        return Pool.effectiveFree(usage.limits, at: now) >= 1
    }

    public static func line(count: Int) -> String {
        "CLIProxyAPI is still holding \(count) \(count == 1 ? "account" : "accounts") in cooldown."
    }

    /// One line for the user to paste with their key in `MANAGEMENT_KEY`, which it never contains.
    /// It stops before any call while the variable is empty: CLIProxyAPI bans an address after five
    /// keyless requests, localhost included, and Ebb reads the proxy from that address too.
    /// Indexes or addresses that aren't plain enough to sit in quotes are left out.
    public static func resetCommand(baseURL: URL, authIndexes: [String]) -> String {
        let endpoint = baseURL.appending(path: "v0/management/reset-quota").absoluteString
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !endpoint.contains("'") else { return "" }
        let calls = authIndexes
            .filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
            .map { #"curl -fsS -X POST -H "Authorization: Bearer $MANAGEMENT_KEY" -H "Content-Type: application/json" -d '{"auth_index":"\#($0)"}' '\#(endpoint)'"# }
        guard !calls.isEmpty else { return "" }
        return #"if [ -z "$MANAGEMENT_KEY" ]; then echo "Set MANAGEMENT_KEY to your CLIProxyAPI management key first." >&2; else "#
            + calls.joined(separator: " && ") + "; fi"
    }
}
