import Foundation

/// A management API address typed by hand, for a proxy on another machine.
public enum ManagementURL {
    public enum Verdict: Sendable, Equatable {
        case ok(URL)
        /// Plain http on a private network: usable, but the key crosses the network in the clear.
        case unencrypted(URL)
        case refused(String)
    }

    /// `https` is always fine. Plain `http` only on loopback, RFC 1918, link-local and unique-local
    /// addresses or `.local` names, where the traffic stays on the user's own network.
    public static func validate(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return .refused("Enter the proxy's address, such as https://proxy.example.com:8317.") }
        guard let host = components.host, !host.isEmpty else { return .refused("The address needs a host name.") }
        // The key is the credential; a user name or password here would only end up on screen in Settings.
        guard components.user == nil, components.password == nil else {
            return .refused("Leave the user name and password out of the address; the management key is the credential.")
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.path = base(of: components.path)
        guard let url = components.url else { return .refused("The address needs a host name.") }
        if scheme == "https" { return .ok(url) }
        guard isPrivate(host: host) else {
            return .refused("Use https: over plain http the management key would cross the internet in the clear.")
        }
        return .unencrypted(url)
    }

    /// The path without the management page or API that was pasted along with it.
    private static func base(of path: String) -> String {
        var trimmed = path
        for suffix in ["/management.html", "/v0/management"] where trimmed.hasSuffix(suffix) || trimmed.hasSuffix(suffix + "/") {
            trimmed = String(trimmed.prefix(trimmed.count - suffix.count - (trimmed.hasSuffix("/") ? 1 : 0)))
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func isPrivate(host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") { return true }
        // An IPv4 address written as IPv6 (`::ffff:192.168.1.5`, or in hex) is that IPv4 address.
        if name.hasPrefix("::ffff:") { return isPrivate(host: mappedIPv4(String(name.dropFirst(7)))) }
        if let octets = ipv4(name) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        guard name.contains(":") else { return false }
        if name == "::1" { return true }
        guard let first = name.split(separator: ":", omittingEmptySubsequences: false).first, let hextet = UInt16(first, radix: 16) else { return false }
        return hextet & 0xffc0 == 0xfe80 || hextet & 0xfe00 == 0xfc00
    }

    /// Dotted form as is; `c0a8:105` becomes `192.168.1.5`. Anything else stays unknown, so not private.
    private static func mappedIPv4(_ tail: String) -> String {
        if tail.contains(".") { return tail }
        let hextets = tail.split(separator: ":").compactMap { UInt16($0, radix: 16) }
        guard hextets.count == 2 else { return "" }
        return hextets.flatMap { [$0 >> 8, $0 & 0xff] }.map(String.init).joined(separator: ".")
    }

    private static func ipv4(_ name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) else { return nil }
        return parts.compactMap { $0 }
    }
}
