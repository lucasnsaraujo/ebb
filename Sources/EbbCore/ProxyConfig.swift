import Foundation

/// Where CLIProxyAPI listens and keeps its logins, read from its YAML config.
/// Understands both the current layout (`server.port`, `oauth.auth-dir`) and the
/// legacy top-level keys (`port`, `auth-dir`).
public struct ProxyConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var usesTLS: Bool
    /// As written in the config; may start with `~`.
    public var authDirectory: String

    public static let defaults = ProxyConfig(host: "127.0.0.1", port: 8317, usesTLS: false, authDirectory: "~/.cli-proxy-api")

    public init(host: String, port: Int, usesTLS: Bool, authDirectory: String) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.authDirectory = authDirectory
    }

    /// The proxy's own address; a server bound to every interface is reached on loopback.
    public var baseURL: URL {
        let reachableHost = ["", "0.0.0.0", "::", "[::]"].contains(host) ? "127.0.0.1" : host
        var components = URLComponents()
        components.scheme = usesTLS ? "https" : "http"
        components.host = reachableHost
        components.port = port
        return components.url ?? URL(string: "http://127.0.0.1:8317")!
    }

    public func authDirectoryURL(home: URL) -> URL {
        if authDirectory == "~" { return home }
        if authDirectory.hasPrefix("~/") { return home.appending(path: String(authDirectory.dropFirst(2))) }
        return URL(fileURLWithPath: authDirectory)
    }

    public static func parse(_ yaml: String) -> ProxyConfig {
        let values = flatten(yaml)
        func value(_ current: String, _ legacy: String) -> String? {
            values[current] ?? values[legacy]
        }
        return ProxyConfig(
            host: value("server.host", "host") ?? defaults.host,
            port: value("server.port", "port").flatMap(Int.init) ?? defaults.port,
            usesTLS: value("server.tls.enable", "tls.enable") == "true",
            authDirectory: value("oauth.auth-dir", "auth-dir").flatMap { $0.isEmpty ? nil : $0 } ?? defaults.authDirectory
        )
    }

    /// Places to look, most specific first: a path set in Settings, `CLIPROXY_CONFIG`,
    /// then the Homebrew and per-user defaults.
    public static func candidatePaths(override: String?, environment: [String: String], home: URL) -> [URL] {
        let paths: [String?] = [
            override,
            environment["CLIPROXY_CONFIG"],
            "/opt/homebrew/etc/cliproxyapi.conf",
            "/usr/local/etc/cliproxyapi.conf",
            home.appending(path: ".cli-proxy-api/config.yaml").path,
        ]
        return paths.compactMap { path in
            guard let path, !path.isEmpty else { return nil }
            return path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))) : URL(fileURLWithPath: path)
        }
    }

    /// Scalar values by dotted path (`server.port`); lists and multi-line values are skipped.
    static func flatten(_ yaml: String) -> [String: String] {
        var values: [String: String] = [:]
        var parents: [(indent: Int, key: String)] = []
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = line.prefix { $0 == " " }.count
            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                parents.append((indent, key))
            } else {
                values[(parents.map(\.key) + [key]).joined(separator: ".")] = unquote(value)
            }
        }
        return values
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || offset == 0 {
                return String(line.prefix(offset))
            }
            previous = character
        }
        return line
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
