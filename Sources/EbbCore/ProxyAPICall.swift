import Foundation

/// A request CLIProxyAPI sends on a login's behalf through `POST /v0/management/api-call`.
/// Ebb names the login by its `auth_index` and writes `$TOKEN$` where the token goes;
/// the proxy fills it in, so Ebb never holds these logins' tokens.
public struct ProxyAPICall: Sendable, Equatable {
    public static let tokenPlaceholder = "$TOKEN$"
    public static let bearer = "Bearer \(tokenPlaceholder)"

    public var authIndex: String
    public var method: String
    public var url: URL
    public var header: [String: String]
    /// Raw request body, sent as is.
    public var data: String?

    public init(authIndex: String, method: String, url: URL, header: [String: String], data: String? = nil) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    /// The JSON body of the `api-call` request.
    public func body() -> Data {
        var object: [String: Any] = [
            "auth_index": authIndex,
            "method": method,
            "url": url.absoluteString,
            "header": header,
        ]
        if let data { object["data"] = data }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

/// What one usage call told Ebb.
public struct UsageCallReading: Sendable, Equatable {
    /// `nil` when the answer carried no windows, as Meta's does while its 5-hour window is idle.
    public var limits: [UsageLimit]?
    public var planName: String?
    /// The provider said in so many words that no subscription is active.
    public var hasEndedSubscription: Bool

    public init(limits: [UsageLimit]?, planName: String?, hasEndedSubscription: Bool = false) {
        self.limits = limits
        self.planName = planName
        self.hasEndedSubscription = hasEndedSubscription
    }
}

public enum CallOutcome: Sendable, Equatable {
    case reading(UsageCallReading)
    /// The provider refused the token the proxy holds, or the proxy had none to send.
    /// Shown as "Limits not available"; it says nothing about the subscription.
    case tokenRejected
    case rateLimited(retryAfter: TimeInterval?)
    case failed

    /// Reads the proxy's answer: HTTP 200 wrapping `{status_code, header, body}`, or
    /// HTTP 400 when it couldn't find a token for the login.
    public static func read(proxyStatus: Int, body: Data, provider: any Provider, now: Date) -> CallOutcome {
        guard proxyStatus == 200 else {
            let message = (Signals.object(body)?["error"] as? String)?.lowercased() ?? ""
            return proxyStatus == 400 && message.contains("token") ? .tokenRejected : .failed
        }
        guard let wrapper = Signals.object(body), let status = Signals.number(wrapper["status_code"]).map(Int.init) else { return .failed }
        switch status {
        case 200:
            let upstream = Data((wrapper["body"] as? String ?? "").utf8)
            return provider.readUsageCall(upstream).map(CallOutcome.reading) ?? .failed
        case 401, 403:
            return .tokenRejected
        case 429:
            let headers = wrapper["header"] as? [String: Any] ?? [:]
            let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
            let text = (value as? [String])?.last ?? value as? String
            return .rateLimited(retryAfter: Backoff.retryAfter(text, now: now))
        default:
            return .failed
        }
    }

    /// What the outcome says about the subscription, for auto-retire: only a definitive
    /// "no active subscription" is `.inactive`. A refused token is never evidence.
    public var subscriptionEvidence: Plan? {
        guard case let .reading(reading) = self else { return nil }
        return reading.hasEndedSubscription ? .inactive : nil
    }
}
