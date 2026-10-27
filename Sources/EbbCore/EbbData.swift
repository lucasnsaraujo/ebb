import Foundation

/// Everything Ebb writes outside its app bundle, for `ebb --uninstall-data` and the Homebrew cask's
/// `zap` stanza (docs/paths.md). Only Ebb's own names appear here: never the proxy's config or its
/// logins folder, and never a folder other apps share, such as `~/.config` or `~/Library/Caches`.
public struct EbbData: Sendable {
    public static let bundleIdentifier = "io.github.lucasnsaraujo.ebb"

    /// Under the home folder. Application Support holds the management key, the demand ledger and the
    /// status file; Caches the account readings plus Sparkle's download folder; Preferences Ebb's settings
    /// and Sparkle's; `.config/ebb` the menu bar mode and the logins Ebb retired.
    public static let homeRelativePaths = [
        ".config/ebb",
        "Library/Application Support/Ebb",
        "Library/Caches/\(bundleIdentifier)",
        "Library/HTTPStorages/\(bundleIdentifier)",
        "Library/HTTPStorages/\(bundleIdentifier).binarycookies",
        "Library/Preferences/\(bundleIdentifier).plist",
        "Library/Saved Application State/\(bundleIdentifier).savedState",
    ]

    public struct Removal: Sendable, Equatable {
        public struct Failure: Sendable, Equatable {
            public var url: URL
            public var reason: String
        }

        public var removed: [URL] = []
        public var failures: [Failure] = []

        public init() {}
    }

    public let home: URL
    /// Where `ebb` may be linked; see `CommandLineTool`.
    public let commandDirectories: [URL]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, commandDirectories: [URL] = CommandLineTool.standardDirectories) {
        self.home = home
        self.commandDirectories = commandDirectories
    }

    public var locations: [URL] {
        Self.homeRelativePaths.map { home.appending(path: $0) }
    }

    /// The `ebb` links that point into an Ebb app. Another program called `ebb` is none of our business.
    public func commandLinks() -> [URL] {
        commandDirectories.map { $0.appending(path: CommandLineTool.name) }.filter { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map(CommandLineTool.isEbbTool) ?? false
        }
    }

    /// What's on disk now. A link to nowhere counts, as it still sits in the folder.
    public func existing() -> [URL] {
        (locations + commandLinks()).filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }
    }

    /// A location that is itself a symbolic link is unlinked, never followed.
    public func remove() -> Removal {
        var removal = Removal()
        for url in existing() {
            do {
                try FileManager.default.removeItem(at: url)
                removal.removed.append(url)
            } catch {
                removal.failures.append(Removal.Failure(url: url, reason: error.localizedDescription))
            }
        }
        return removal
    }
}
