import Foundation

/// A provider's public status, as its Statuspage-style `summary.json` reports its components.
public enum ServiceHealth: Int, Sendable, Equatable, Comparable, Codable {
    case operational, underMaintenance, degradedPerformance, partialOutage, majorOutage

    init?(statuspage value: String) {
        switch value {
        case "operational": self = .operational
        case "under_maintenance": self = .underMaintenance
        case "degraded_performance": self = .degradedPerformance
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        default: return nil
        }
    }

    public static func < (lhs: ServiceHealth, rhs: ServiceHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func words(locale: Locale) -> String {
        switch self {
        case .operational: Localization.text("operational", locale: locale)
        case .underMaintenance: Localization.text("under maintenance", locale: locale)
        case .degradedPerformance: Localization.text("degraded performance", locale: locale)
        case .partialOutage: Localization.text("partial outage", locale: locale)
        case .majorOutage: Localization.text("major outage", locale: locale)
        }
    }

    /// "Claude: degraded performance", or `nil` while all is well.
    public func line(title: String, locale: Locale = .autoupdatingCurrent) -> String? {
        self == .operational ? nil : Localization.text("\(title): \(words(locale: locale))", locale: locale)
    }
}

/// Where a provider publishes its status, and which of its components a pool depends on.
public struct StatusPage: Sendable, Equatable {
    /// At most this often, and only while the menu bar item shows.
    public static let pollInterval: TimeInterval = 5 * 60

    public var summaryURL: URL
    public var pageURL: URL
    /// Components whose name contains one of these.
    var components: [String]

    public static func forProvider(_ provider: String) -> StatusPage? {
        switch Providers.named(provider)?.proxyName {
        case "claude":
            StatusPage(summaryURL: URL(string: "https://status.claude.com/api/v2/summary.json")!,
                       pageURL: URL(string: "https://status.claude.com")!, components: ["Claude API", "Claude Code"])
        case "codex":
            StatusPage(summaryURL: URL(string: "https://status.openai.com/api/v2/summary.json")!,
                       pageURL: URL(string: "https://status.openai.com")!, components: ["Codex", "Responses"])
        default: nil
        }
    }

    /// The worst status among the pool's components; `nil` when the page can't be read or lists none of them.
    public func health(from data: Data) -> ServiceHealth? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = body["components"] as? [[String: Any]]
        else { return nil }
        let states = items
            .filter { item in (item["name"] as? String).map { name in components.contains { name.contains($0) } } ?? false }
            .compactMap { ($0["status"] as? String).flatMap(ServiceHealth.init(statuspage:)) }
        return states.max()
    }
}

/// When each pool's status page was last read, and the problems found. Each provider is read
/// on its own schedule, so one that joins later is read at once; a failed read keeps what was known.
public struct StatusPageReads: Sendable, Equatable {
    private var readAt: [String: Date] = [:]
    /// Pools whose page reports a problem.
    public private(set) var incidents: [String: ServiceHealth] = [:]

    public init() {}

    /// Providers with a status page not read within `StatusPage.pollInterval`.
    public func due(_ providers: [String], now: Date) -> [String] {
        providers.filter { provider in
            StatusPage.forProvider(provider) != nil
                && readAt[provider].map { now.timeIntervalSince($0) >= StatusPage.pollInterval } ?? true
        }
    }

    /// `health` is `nil` when the read failed.
    public mutating func record(_ provider: String, health: ServiceHealth?, now: Date) {
        readAt[provider] = now
        guard let health else { return }
        incidents[provider] = health == .operational ? nil : health
    }
}

/// Decides which incidents are news: a provider going from fine to a problem, or a problem
/// getting worse. Maintenance is planned, so it never alerts, and a status that flaps back
/// within an hour isn't a new problem. Saved between launches.
public struct IncidentTracker: Codable, Sendable, Equatable {
    /// A problem that comes back sooner than this after the last one is the same problem.
    static let recoveryQuiet: TimeInterval = 60 * 60

    private var announced: [String: ServiceHealth] = [:]
    private var lastProblemAt: [String: Date] = [:]

    public init() {}

    public mutating func alerts(provider: String, title: String, health: ServiceHealth, now: Date, locale: Locale = .autoupdatingCurrent) -> [PoolAlert] {
        if let last = lastProblemAt[provider], now.timeIntervalSince(last) >= Self.recoveryQuiet {
            announced[provider] = nil
            lastProblemAt[provider] = nil
        }
        guard health > .underMaintenance else { return [] }
        lastProblemAt[provider] = now
        guard health > announced[provider] ?? .underMaintenance, let line = health.line(title: title, locale: locale) else { return [] }
        announced[provider] = health
        let host = StatusPage.forProvider(provider)?.pageURL.host() ?? Localization.text("its status page", locale: locale)
        return [PoolAlert(
            id: "incident.\(provider).\(health.rawValue)", title: line,
            body: Localization.text("Reported on \(host). Sessions may fail or slow down until it clears.", locale: locale)
        )]
    }
}
