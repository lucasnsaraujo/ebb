import Foundation

/// Puts the `ebb` command that ships inside the app on the user's PATH, as a symbolic link,
/// without admin rights: into the first folder the user can write to, creating the last one if needed.
public struct CommandLineTool: Sendable {
    public enum InstallError: Error, Equatable {
        /// Something that isn't Ebb's link already has the name.
        case occupied(URL)
        case noWritableFolder
        /// macOS is running Ebb from a temporary copy (App Translocation), which a link would outlive.
        case translocated
    }

    public static let name = "ebb"
    /// `/usr/local/bin` when it's writable (Homebrew on Intel makes it so), else `~/.local/bin`.
    public static let standardDirectories = [
        URL(fileURLWithPath: "/usr/local/bin"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin"),
    ]

    /// The binary inside the app bundle.
    public let tool: URL
    /// Tried in order; the last one is created when none is writable.
    public let directories: [URL]

    public init(tool: URL, directories: [URL] = standardDirectories) {
        self.tool = tool
        self.directories = directories
    }

    /// A link in one of `directories` that points at this tool.
    public var installedLink: URL? {
        directories.map { $0.appending(path: Self.name) }.first { destination(of: $0) == tool.path }
    }

    /// Links the tool and returns where. An older link to any copy of Ebb is replaced.
    @discardableResult
    public func install() throws -> URL {
        let manager = FileManager.default
        guard !tool.path.contains("/AppTranslocation/") else { throw InstallError.translocated }
        guard let directory = try writableDirectory() else { throw InstallError.noWritableFolder }
        let link = directory.appending(path: Self.name)
        if let existing = destination(of: link) {
            guard Self.isEbbTool(existing) else { throw InstallError.occupied(link) }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw InstallError.occupied(link)
        }
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
        return link
    }

    private func writableDirectory() throws -> URL? {
        let manager = FileManager.default
        if let found = directories.first(where: { manager.isWritableFile(atPath: $0.path) }) { return found }
        guard let last = directories.last, !manager.fileExists(atPath: last.path) else { return nil }
        try manager.createDirectory(at: last, withIntermediateDirectories: true)
        return last
    }

    private func destination(of link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    /// The tool inside any copy of Ebb, renamed ones like `Ebb 2.app` included.
    static func isEbbTool(_ path: String) -> Bool {
        let components = Array(URL(fileURLWithPath: path).pathComponents.suffix(4))
        guard components.count == 4 else { return false }
        return components[0].hasPrefix("Ebb") && components[0].hasSuffix(".app") && Array(components[1...]) == ["Contents", "Helpers", name]
    }
}
