import Foundation

/// The CLIProxyAPI management key, kept in a file only the user can read. The proxy stores
/// just a hash of it, so Ebb has to keep the key itself. Not in the Keychain: an ad-hoc
/// signed build changes signature on every rebuild, and the Keychain then asks for access
/// to the item again, which stops Ebb at launch.
public struct ManagementKeyFile: Sendable {
    /// A plain copy of the key that some CLIProxyAPI setups keep in the logins folder.
    public static let importName = ".management-key"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> ManagementKey? {
        Self.key(at: url)
    }

    public enum Origin: Sendable, Equatable {
        case saved
        /// Read from the logins folder and not saved yet: save it once the proxy accepts it,
        /// so a wrong copy never sticks.
        case loginsFolder
    }

    /// The saved key; without one, the `.management-key` file in `authDirectory`.
    public func load(importingFrom authDirectory: URL?) -> (key: ManagementKey, origin: Origin)? {
        if let saved = read() { return (saved, .saved) }
        guard let authDirectory, let found = Self.key(at: authDirectory.appending(path: Self.importName)) else { return nil }
        return (found, .loginsFolder)
    }

    /// The folder is made owner-only (0700) before the file is written, so the file is never
    /// readable by others, even before its own mode becomes 0600.
    public func save(_ key: ManagementKey) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(key.value.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func key(at url: URL) -> ManagementKey? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(ManagementKey.init)
    }
}

/// A management key whose printed forms hide it, so logging anything that holds one can't leak it.
public struct ManagementKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    /// `nil` when nothing is left after trimming whitespace and newlines.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        value = trimmed
    }

    public var description: String { "ManagementKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
