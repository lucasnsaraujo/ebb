import Foundation

/// How a provider request ended, in the words the diagnostics use.
public enum RequestOutcome: String, Sendable, Equatable {
    case ok
    case rateLimited = "rate limited"
    case tokenRefused = "token refused"
    case failed
}

/// The last events worth a bug report, in memory only: proxy polls failing and recovering,
/// provider requests by outcome, wakes. Callers name logins by their diagnostics label, never
/// by email or file name, and the report scrubs every line again on its way out.
@MainActor
public final class DiagnosticLog {
    public struct Entry: Sendable, Equatable {
        public var date: Date
        public var message: String
    }

    nonisolated public static let capacity = 20

    public private(set) var entries: [Entry] = []

    public init() {}

    public func record(_ message: String, at date: Date = .now) {
        entries.append(Entry(date: date, message: message))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}

/// One login as the report describes it.
public struct DiagnosticAccount: Sendable, Equatable {
    public var provider: String
    /// Email or auth file name: fixes the login's number and never appears in the text.
    public var name: String
    public var status: String
    public var readAt: Date?
    public var outcome: RequestOutcome?

    public init(provider: String, name: String, status: String, readAt: Date?, outcome: RequestOutcome?) {
        self.provider = provider
        self.name = name
        self.status = status
        self.readAt = readAt
        self.outcome = outcome
    }
}

public struct DiagnosticsReport: Sendable {
    public var ebbVersion: String
    public var macOSVersion: String
    public var proxyVersion: String?
    /// "local, reachable", "remote, refused the key", "no management key".
    public var connection: String
    public var routingStrategy: String?
    public var accounts: [DiagnosticAccount]
    public var log: [DiagnosticLog.Entry]
    /// Values that must not appear whatever a line says: the management key.
    public var secrets: [String]
    /// Each provider's pool, as the panel reads it.
    public var pools: [String: PoolSummary]

    public init(ebbVersion: String, macOSVersion: String, proxyVersion: String?, connection: String, routingStrategy: String?, accounts: [DiagnosticAccount], log: [DiagnosticLog.Entry], secrets: [String], pools: [String: PoolSummary] = [:]) {
        self.ebbVersion = ebbVersion
        self.macOSVersion = macOSVersion
        self.proxyVersion = proxyVersion
        self.connection = connection
        self.routingStrategy = routingStrategy
        self.accounts = accounts
        self.log = log
        self.secrets = secrets
        self.pools = pools
    }
}

/// The plain text behind Copy Diagnostics.
public enum Diagnostics {
    /// `claude#1`, `claude#2`: numbered within each provider in name order, so the report
    /// and the log lines written before it agree.
    public static func label(provider: String, name: String, among accounts: [DiagnosticAccount]) -> String {
        let names = accounts.filter { $0.provider == provider }.map(\.name).sorted()
        let index = names.firstIndex(of: name).map { $0 + 1 } ?? names.count + 1
        return "\(provider)#\(index)"
    }

    public static func text(_ report: DiagnosticsReport, now: Date) -> String {
        var lines = [
            "Ebb \(report.ebbVersion) · macOS \(report.macOSVersion) · CLIProxyAPI \(report.proxyVersion ?? "unknown version")",
            "Proxy: \(report.connection)",
            "Routing: \(report.routingStrategy ?? "unknown")",
        ]
        let counts = Dictionary(report.accounts.map { ($0.provider, 1) }, uniquingKeysWith: +)
        lines.append("Providers: " + (counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        lines.append("")
        for account in report.accounts.sorted(by: { ($0.provider, $0.name) < ($1.provider, $1.name) }) {
            let read = account.readAt.map { "read \(age($0, now: now)) ago" } ?? "never read"
            lines.append([label(provider: account.provider, name: account.name, among: report.accounts), account.status, read, account.outcome?.rawValue ?? "no request yet"].joined(separator: "  "))
        }
        lines.append("")
        for (provider, pool) in report.pools.sorted(by: { $0.key < $1.key }) {
            var short = "\(Providers.named(provider)?.shortWindow == .day ? "daily" : "5h") \(percent(pool.session.freePercent)) left"
            if pool.session.lockedPercent > 0 {
                short += ", \(percent(pool.session.lockedPercent)) locked" + (pool.session.unlocksAt.map { ", unlocks in \(ahead($0, now: now))" } ?? "")
            }
            lines.append("Pool \(provider): \(short); weekly \(percent(pool.weekly.freePercent)) left")
        }
        if !report.pools.isEmpty { lines.append("") }
        lines.append("Log")
        for entry in report.log.suffix(DiagnosticLog.capacity) {
            lines.append("\(clock(entry.date))  \(entry.message)")
        }
        return Redaction.scrub(lines.joined(separator: "\n"), secrets: report.secrets)
    }

    private static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "40m", "26h": hours keep a day-long wait exact enough to match against the log.
    private static func ahead(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_US_POSIX")).hour(.twoDigits(amPM: .omitted)))
    }
}

/// Strips what must never leave the Mac: known secrets, auth file names (which carry emails),
/// anything named like a token or key in JSON or a query string, bearer tokens and `sk-…` keys,
/// emails (encoded ones too), UUIDs and hex keys, home folder names, and any other long opaque string.
public enum Redaction {
    public static func scrub(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "‹redacted›")
        }
        result = result.replacing(/[^\s"'`]+\.json\b/, with: "‹auth file›")
        result = result.replacing(/("[^"]*(?i:token|key|secret|password)[^"]*"\s*:\s*)"[^"]*"/) { "\($0.1)\"‹redacted›\"" }
        result = result.replacing(/([?&][^=&\s]*(?i:token|key|secret|password)[^=&\s]*=)[^&\s]+/) { "\($0.1)‹redacted›" }
        result = result.replacing(/Bearer\s+\S+/, with: "Bearer ‹token›")
        result = result.replacing(/\bsk-[A-Za-z0-9_\-]{6,}/, with: "‹token›")
        result = result.replacing(/[A-Za-z0-9._%+\-]+(@|%40)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, with: "‹email›")
        result = result.replacing(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/, with: "‹id›")
        result = result.replacing(/\b[0-9a-fA-F]{32,}\b/, with: "‹key›")
        result = result.replacing(/(\/(?:Users|home)\/)[^\/\s]+/) { "\($0.1)‹user›" }
        result = result.replacing(/\b[A-Za-z0-9_\-]{40,}\b/, with: "‹token›")
        return result
    }
}
