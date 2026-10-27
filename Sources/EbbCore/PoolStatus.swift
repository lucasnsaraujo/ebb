import Foundation

/// The pools as the app last saw them, saved for readers outside it: the `ebb` command,
/// Shortcuts and widgets. Pool level only; accounts never appear here.
public struct PoolStatus: Sendable, Equatable, Codable {
    /// A reader skips a file with any other version rather than misread it.
    public static let currentVersion = 1
    /// Unchanged numbers are rewritten this often, so a reader can tell a live app from a stopped one.
    public static let refreshInterval: TimeInterval = 5 * 60
    /// A file older than this is from an app that quit or whose item was hidden.
    public static let staleAge: TimeInterval = 2 * refreshInterval
    /// `~/Library/Application Support/Ebb/status.json`.
    public static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Ebb/status.json")

    public var version = currentVersion
    /// When the app worked these numbers out.
    public var updatedAt: Date
    /// The pool the menu bar shows, which the one-line summary follows.
    public var menuBarProvider: String?
    /// In `Providers.all` order.
    public var providers: [ProviderStatus]

    public init(updatedAt: Date, menuBarProvider: String?, providers: [ProviderStatus]) {
        self.updatedAt = updatedAt
        self.menuBarProvider = menuBarProvider
        self.providers = providers
    }

    /// The pools of `providers`, in that order; one without a summary is left out.
    /// `readAt` is each pool's newest reading, as the menu bar judges staleness.
    public init(summaries: [String: PoolSummary], providers: [String], readAt: [String: Date], menuBarProvider: String?, updatedAt: Date) {
        let statuses = providers.compactMap { id -> ProviderStatus? in
            guard let summary = summaries[id] else { return nil }
            let provider = Providers.named(id)
            return ProviderStatus(
                id: id,
                title: provider?.title ?? id,
                shortWindow: provider?.shortWindow ?? .fiveHours,
                session: WindowStatus(freePercent: summary.session.freePercent, resets: summary.session.resets),
                weekly: WindowStatus(freePercent: summary.weekly.freePercent, resets: summary.weekly.resets),
                isPartial: summary.isPartial,
                readAt: readAt[id]
            )
        }
        self.init(updatedAt: updatedAt, menuBarProvider: menuBarProvider, providers: statuses)
    }

    /// Worth saving over `previous`, the status last written. A newer reading of the same numbers
    /// waits for the refresh, since the proxy is read every 30 seconds.
    public func needsWrite(after previous: PoolStatus?) -> Bool {
        guard let previous else { return true }
        // Only a newer time for a reading already there waits; a pool's first reading is news.
        func numbers(_ status: PoolStatus) -> [ProviderStatus] {
            status.providers.map { var pool = $0; pool.readAt = pool.readAt.map { _ in .distantPast }; return pool }
        }
        return numbers(previous) != numbers(self) || previous.menuBarProvider != menuBarProvider
            || updatedAt.timeIntervalSince(previous.updatedAt) >= Self.refreshInterval
    }

    /// `nil` when the file is missing, unreadable or of another version.
    public static func read(from file: URL = defaultFile) -> PoolStatus? {
        guard let data = try? Data(contentsOf: file),
              let status = try? decoder.decode(PoolStatus.self, from: data),
              status.version == currentVersion
        else { return nil }
        return status
    }

    public func write(to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// One provider's pool: its two windows, never blended.
public struct ProviderStatus: Sendable, Equatable, Codable {
    /// CLIProxyAPI's name for the provider, such as `claude`.
    public var id: String
    public var title: String
    public var shortWindow: ShortWindow
    public var session: WindowStatus
    public var weekly: WindowStatus
    /// Some login had no usable reading and is left out of the numbers.
    public var isPartial: Bool
    /// The newest reading behind the numbers; `nil` while the proxy doesn't answer and nothing else was read.
    public var readAt: Date?

    public init(id: String, title: String, shortWindow: ShortWindow, session: WindowStatus, weekly: WindowStatus, isPartial: Bool, readAt: Date?) {
        self.id = id
        self.title = title
        self.shortWindow = shortWindow
        self.session = session
        self.weekly = weekly
        self.isPartial = isPartial
        self.readAt = readAt
    }

    /// No reading, or none for over `MenuBarItem.staleAfter`: the menu bar dims for the same.
    public func isStale(at now: Date) -> Bool {
        readAt.map { now.timeIntervalSince($0) > MenuBarItem.staleAfter } ?? true
    }
}

/// One window as of `PoolStatus.updatedAt`, plus the capacity that comes back after it.
public struct WindowStatus: Sendable, Equatable, Codable {
    public var freePercent: Double
    /// Soonest first.
    public var resets: [Restoration]

    public init(freePercent: Double, resets: [Restoration]) {
        self.freePercent = freePercent
        self.resets = resets
    }

    /// Free share at `date`: what was free, plus every reset that has landed since.
    public func free(at date: Date) -> Double {
        min(100, freePercent + resets.filter { $0.date <= date }.reduce(0) { $0 + $1.gain })
    }

    /// The first reset still ahead that gives back at least a whole point once rounded.
    public func nextRefill(at date: Date) -> Restoration? {
        resets.first { $0.date > date && $0.gain >= 0.5 }
    }
}
