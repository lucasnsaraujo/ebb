import EbbCore
import Foundation
import Observation

/// Finds CLIProxyAPI's config and holds the management key. Without a working key,
/// Ebb still reads logins from the auth folder and asks providers directly.
@MainActor
@Observable
final class ProxyConnection {
    enum KeyState: Equatable {
        case missing, checking, valid, rejected, unreachable
    }

    private static let configOverrideKey = "proxyConfigPath"

    private(set) var configFile: URL?
    private(set) var config = ProxyConfig.defaults
    private(set) var keyState: KeyState = .missing
    /// `nil` until read, or when the proxy can't be asked.
    private(set) var routingStrategy: String?

    @ObservationIgnored private var key: String?
    @ObservationIgnored private let client = ProxyClient()

    init() {
        discover()
        key = ManagementKeychain.read()
        keyState = key == nil ? .missing : .checking
    }

    var configOverride: String? {
        UserDefaults.standard.string(forKey: Self.configOverrideKey)
    }

    var authDirectory: URL {
        config.authDirectoryURL(home: EbbPaths.home)
    }

    var managementPage: URL {
        config.baseURL.appending(path: "management.html")
    }

    /// Present whenever a key is saved; calls fail quietly if the proxy refuses it.
    var endpoint: ProxyEndpoint? {
        key.map { ProxyEndpoint(baseURL: config.baseURL, key: $0) }
    }

    var hasManagementAccess: Bool {
        keyState == .valid
    }

    func setConfigOverride(_ path: String?) {
        UserDefaults.standard.set(path, forKey: Self.configOverrideKey)
        discover()
    }

    /// The first config file that exists, or the proxy's defaults.
    func discover() {
        let candidates = ProxyConfig.candidatePaths(override: configOverride, environment: ProcessInfo.processInfo.environment, home: EbbPaths.home)
        configFile = candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
        config = configFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(ProxyConfig.parse) ?? .defaults
    }

    /// Checks the key against the live proxy and keeps it only if accepted.
    func save(key newKey: String) async {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyState = .checking
        let result = await client.check(ProxyEndpoint(baseURL: config.baseURL, key: trimmed))
        switch result {
        case .valid:
            key = ManagementKeychain.save(trimmed) ? trimmed : nil
            keyState = key == nil ? .missing : .valid
            await refreshRoutingStrategy()
        case .rejected:
            keyState = .rejected
        case .unreachable:
            keyState = .unreachable
        }
    }

    func forgetKey() {
        ManagementKeychain.delete()
        key = nil
        keyState = .missing
        routingStrategy = nil
    }

    func test() async {
        guard let endpoint else {
            keyState = .missing
            return
        }
        keyState = .checking
        keyState = switch await client.check(endpoint) {
        case .valid: .valid
        case .rejected: .rejected
        case .unreachable: .unreachable
        }
        if keyState == .valid { await refreshRoutingStrategy() }
    }

    func refreshRoutingStrategy() async {
        routingStrategy = if let endpoint { await client.routingStrategy(endpoint) } else { nil }
    }

    /// Only ever called from the button in Settings: Ebb never changes proxy config on its own.
    func useWeightedRouting() async {
        guard let endpoint else { return }
        if await client.setRoutingStrategy(ProxyClient.weightedRoundRobin, endpoint) {
            await refreshRoutingStrategy()
        }
    }
}
