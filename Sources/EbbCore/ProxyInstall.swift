import Foundation

/// How CLIProxyAPI is installed, for the panel's offer to start it when it isn't running.
public enum ProxyInstall: Sendable, Equatable {
    /// A Homebrew formula under `prefix`, which `brew services` starts.
    case homebrew(prefix: String)
    /// Anything else: Ebb can only show how to start it.
    case other

    public static let formula = "cliproxyapi"
    public static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// Homebrew when `brew` and the formula are both under one of its prefixes.
    public static func detect(fileExists: (String) -> Bool) -> ProxyInstall {
        for prefix in homebrewPrefixes where fileExists("\(prefix)/bin/brew") && fileExists("\(prefix)/opt/\(formula)") {
            return .homebrew(prefix: prefix)
        }
        return .other
    }

    /// What Ebb can run itself: the prefix's own `brew`, since the PATH of an app is bare.
    public var launch: (executable: String, arguments: [String])? {
        guard case let .homebrew(prefix) = self else { return nil }
        return ("\(prefix)/bin/brew", ["services", "start", Self.formula])
    }

    /// The command to show, and to copy for the Terminal.
    public func command(configFile: String?) -> String {
        switch self {
        case .homebrew: "brew services start \(Self.formula)"
        case .other: configFile.map { "\(Self.formula) -config \(Self.quoted($0))" } ?? Self.formula
        }
    }

    private static func quoted(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
