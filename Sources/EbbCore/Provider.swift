import Foundation

/// One kind of subscription CLIProxyAPI can pool. Everything specific to a vendor's
/// API lives behind this boundary; the pool math only sees limits and plans.
public protocol Provider: Sendable {
    /// CLIProxyAPI's name for it: the auth files' `type` and the management API's `provider`.
    var proxyName: String { get }
    /// The request for an account's current limits. Must not spend quota.
    func usageRequest(accessToken: String) -> URLRequest
    /// `nil` when the response can't be read.
    func parseUsage(_ data: Data) -> [UsageLimit]?
    /// The request for an account's plan.
    func planRequest(accessToken: String) -> URLRequest
    /// `nil` when the plan fields are missing, so a changed API never reads as a cancelled plan.
    func parsePlan(_ data: Data) -> PlanProfile?
    /// Limits from the rate-limit headers CLIProxyAPI captured from the account's latest response.
    func limits(fromSignals signals: [String: Any]) -> [UsageLimit]?
}

public enum Providers {
    public static let all: [any Provider] = [ClaudeProvider()]

    public static func named(_ name: String?) -> (any Provider)? {
        all.first { $0.proxyName == name }
    }
}
