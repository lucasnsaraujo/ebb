import Foundation

/// One kind of subscription CLIProxyAPI can pool with real usage windows. Everything specific
/// to a vendor's API lives behind this boundary; the pool math only sees limits and plans.
/// Logins of any other provider are listed for their health only and never counted.
public protocol Provider: Sendable {
    /// CLIProxyAPI's name for it: the auth files' `type` and the management API's `provider`.
    var proxyName: String { get }
    /// Other names CLIProxyAPI gives the same subscription (`kimi-ai` for Kimi's international site).
    var otherProxyNames: [String] { get }
    var title: String { get }
    /// The shorter of the two windows the pool shows.
    var shortWindow: ShortWindow { get }
    /// Limits from the quota signals CLIProxyAPI keeps for the login. `nil` without a usable window.
    func limits(fromSignals signals: [String: Any], observedAt: Date) -> [UsageLimit]?
    /// The plan named in the login's listing entry or its signals.
    func planName(fromEntry entry: [String: Any]) -> String?
    /// One read of the login's limits through CLIProxyAPI's `api-call`, which fills in the token.
    func usageCall(for login: ProxyAuthFile) -> ProxyAPICall?
    /// `nil` when the body can't be read, so a changed API never reads as an empty account.
    func readUsageCall(_ body: Data) -> UsageCallReading?
}

extension Provider {
    public var otherProxyNames: [String] { [] }
    public var shortWindow: ShortWindow { .fiveHours }
    public func limits(fromSignals signals: [String: Any], observedAt: Date) -> [UsageLimit]? { nil }
    public func planName(fromEntry entry: [String: Any]) -> String? { nil }
    public func usageCall(for login: ProxyAuthFile) -> ProxyAPICall? { nil }
    public func readUsageCall(_ body: Data) -> UsageCallReading? { nil }
}

/// The pool's shorter window. Devin meters by day; the rest by five hours.
public enum ShortWindow: String, Sendable, Equatable, Codable {
    case fiveHours, day

    /// Resets further out than this don't belong in the "comes back soon" line.
    public var horizon: TimeInterval {
        switch self {
        case .fiveHours: 5 * 60 * 60
        case .day: 24 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .fiveHours: "5-hour"
        case .day: "Daily"
        }
    }

    /// The account columns' header and the menu bar's prefix.
    public var abbreviation: String {
        switch self {
        case .fiveHours: "5h"
        case .day: "1d"
        }
    }
}

public enum Providers {
    public static let all: [any Provider] = [
        ClaudeProvider(), CodexProvider(), DevinProvider(), AntigravityProvider(), KimiProvider(), MetaProvider(),
    ]

    public static func named(_ name: String?) -> (any Provider)? {
        guard let name = name?.lowercased() else { return nil }
        return all.first { $0.proxyName == name || $0.otherProxyNames.contains(name) }
    }
}

/// Signal values arrive as strings, keyed by canonical header names (`X-Codex-Primary-Used-Percent`).
enum Signals {
    static func lowercased(_ signals: [String: Any]) -> [String: String] {
        Dictionary(signals.compactMap { key, value -> (String, String)? in
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue
            return text.map { (key.lowercased(), $0.trimmingCharacters(in: .whitespaces)) }
        }) { first, _ in first }
    }

    /// Whole-window length to the pool window it fills: a day or less is the short one, a week the long one.
    static func kind(windowMinutes: Double) -> UsageLimit.Kind? {
        switch windowMinutes {
        case 1...(24 * 60): .session
        case (6 * 24 * 60)...(8 * 24 * 60): .weeklyAll
        default: nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let seconds = Double(text) { return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil }
            return UsageLimit.parseTimestamp(text)
        }
        return number(value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func percent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
