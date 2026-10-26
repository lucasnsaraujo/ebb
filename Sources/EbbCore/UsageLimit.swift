import Foundation

/// One rate-limit window of an account, in Claude's `GET /api/oauth/usage` terms;
/// every provider's windows are mapped onto these kinds.
public struct UsageLimit: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        case session
        case weeklyAll
        /// Model-specific weekly cap; it never limits the pool as a whole.
        case weeklyScoped
        case other(String)

        var rawName: String {
            switch self {
            case .session: "session"
            case .weeklyAll: "weekly_all"
            case .weeklyScoped: "weekly_scoped"
            case let .other(name): name
            }
        }
    }

    public var kind: Kind
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Decodes the `limits` array, which is also the format of the cache files.
    public static func decodeList(from data: Data) throws -> [UsageLimit] {
        try JSONDecoder().decode([UsageLimit].self, from: data)
    }

    /// Encodes limits in the usage endpoint's shape, the format of the cache files.
    public static func encodeList(_ limits: [UsageLimit]) -> Data {
        let objects = limits.map { limit -> [String: Any] in
            [
                "kind": limit.kind.rawName,
                "group": limit.kind == .session ? "session" : "weekly",
                "percent": limit.usedPercent,
                "resets_at": limit.resetsAt.map { $0.formatted(.iso8601) } ?? NSNull(),
                "scope": NSNull(),
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    /// Usage at `now`: a window whose reset time has passed starts over at zero.
    public func used(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

extension UsageLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, percent
        case resetsAt = "resets_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = switch try container.decode(String.self, forKey: .kind) {
        case "session": .session
        case "weekly_all": .weeklyAll
        case "weekly_scoped": .weeklyScoped
        case let other: .other(other)
        }
        usedPercent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt).flatMap(Self.parseTimestamp)
    }

    /// The API sends `2026-10-27T00:09:59.819373+00:00`, and sometimes no fraction at all.
    static func parseTimestamp(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
