import EbbCore
import Foundation
import Observation

/// Finds CLIProxyAPI's config and holds the management key. Without a working key, a proxy on
/// this Mac still has its Claude logins read from the auth folder and asked directly; a proxy
/// on another machine, reached by a hand-set address, needs the key for everything.
@MainActor
@Observable
final class ProxyConnection {
    enum KeyState: Equatable {
        case missing, checking, valid, rejected, unreachable
    }

    private static let configOverrideKey = "proxyConfigPath"
    /// Set by Forget Key, so the logins folder's `.management-key` isn't imported again.
    private static let forgotKeyKey = "forgotManagementKey"
    private static let managementURLKey = "managementURL"

    enum StartState: Equatable {
        case idle, starting
        case failed(String)
    }

    private(set) var configFile: URL?
    private(set) var config = ProxyConfig.defaults
    /// An address set by hand in Settings, for a proxy on another machine; `nil` follows the config file.
    private(set) var managementURL: URL?
    private(set) var keyState: KeyState = .missing
    /// `nil` until read, or when the proxy can't be asked.
    private(set) var routingStrategy: String?
    private(set) var startState: StartState = .idle
    /// From the `X-Cpa-Version` header of the last answer, a refusal included.
    private(set) var proxyVersion: String?
    /// Found at launch: whether the Start button can do anything.
    let install = ProxyInstall.detect { FileManager.default.fileExists(atPath: $0) }
    /// Shared with the store: one log for everything Copy Diagnostics reports.
    let diagnostics: DiagnosticLog

    @ObservationIgnored private var key: ManagementKey?
    /// A key read from the logins folder, saved only once the proxy accepts it.
    @ObservationIgnored private var unsavedKey: ManagementKey?
    @ObservationIgnored private let client = ProxyClient()
    @ObservationIgnored private let keyFile = ManagementKeyFile(url: EbbPaths.managementKeyFile)

    init(diagnostics: DiagnosticLog = DiagnosticLog()) {
        self.diagnostics = diagnostics
        discover()
        // Checked again on every launch: a value written behind Settings' back gets no exception.
        switch UserDefaults.standard.string(forKey: Self.managementURLKey).map(ManagementURL.validate) {
        case let .ok(url), let .unencrypted(url): managementURL = url
        case .refused:
            UserDefaults.standard.removeObject(forKey: Self.managementURLKey)
            diagnostics.record("Saved proxy address refused; using the config file")
        case nil: break
        }
        // A snapshot or demo reads a key only from `--key-file`, never the user's saved one.
        if LaunchOptions.snapshotDirectory != nil || LaunchOptions.isDemo {
            key = LaunchOptions.snapshotKey
        } else {
            let loaded = keyFile.load(importingFrom: UserDefaults.standard.bool(forKey: Self.forgotKeyKey) ? nil : localAuthDirectory)
            key = loaded?.key
            unsavedKey = loaded?.origin == .loginsFolder ? loaded?.key : nil
        }
        keyState = key == nil ? .missing : .checking
    }

    var configOverride: String? {
        UserDefaults.standard.string(forKey: Self.configOverrideKey)
    }

    /// The proxy runs on another machine: its logins folder is out of reach, so every login,
    /// Claude's included, is read through the management API.
    var isRemote: Bool {
        managementURL != nil
    }

    var baseURL: URL {
        managementURL ?? config.baseURL
    }

    /// CLIProxyAPI's logins folder, read only while the proxy runs on this Mac.
    var localAuthDirectory: URL? {
        isRemote ? nil : config.authDirectoryURL(home: EbbPaths.home)
    }

    var managementPage: URL {
        baseURL.appending(path: "management.html")
    }

    /// Present whenever a key is saved; calls fail quietly if the proxy refuses it.
    var endpoint: ProxyEndpoint? {
        key.map { ProxyEndpoint(baseURL: baseURL, key: $0) }
    }

    var hasManagementAccess: Bool {
        keyState == .valid
    }

    func setConfigOverride(_ path: String?) {
        UserDefaults.standard.set(path, forKey: Self.configOverrideKey)
        discover()
    }

    /// Already validated by `ManagementURL`; `nil` goes back to the config file's address.
    func setManagementURL(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString, forKey: Self.managementURLKey)
        managementURL = url
        diagnostics.record(url == nil ? "Proxy address: from the config file" : "Proxy address: set by hand")
        proxyVersion = nil
        routingStrategy = nil
        Task { await test() }
    }

    /// The first config file that exists, or the proxy's defaults.
    func discover() {
        let candidates = ProxyConfig.candidatePaths(override: configOverride, environment: ProcessInfo.processInfo.environment, home: EbbPaths.home)
        configFile = candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
        config = configFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(ProxyConfig.parse) ?? .defaults
    }

    /// Checks the key against the live proxy and keeps it only if accepted.
    func save(key newKey: String) async {
        guard let newKey = ManagementKey(newKey) else { return }
        keyState = .checking
        let result = await client.check(ProxyEndpoint(baseURL: baseURL, key: newKey))
        noteProxyVersion(result.version)
        diagnostics.record("Key saved from Settings: \(result.check)")
        switch result.check {
        case .valid:
            key = (try? keyFile.save(newKey)) == nil ? nil : newKey
            keyState = key == nil ? .missing : .valid
            unsavedKey = nil
            UserDefaults.standard.removeObject(forKey: Self.forgotKeyKey)
            await refreshRoutingStrategy()
        case .rejected:
            keyState = .rejected
        case .unreachable:
            keyState = .unreachable
        }
    }

    func forgetKey() {
        keyFile.delete()
        UserDefaults.standard.set(true, forKey: Self.forgotKeyKey)
        key = nil
        unsavedKey = nil
        keyState = .missing
        routingStrategy = nil
    }

    func test() async {
        guard let endpoint else {
            keyState = .missing
            return
        }
        keyState = .checking
        let result = await client.check(endpoint)
        noteProxyVersion(result.version)
        diagnostics.record("Key check: \(result.check)")
        keyState = switch result.check {
        case .valid: .valid
        case .rejected: .rejected
        case .unreachable: .unreachable
        }
        guard keyState == .valid else { return }
        if let unsavedKey, (try? keyFile.save(unsavedKey)) != nil { self.unsavedKey = nil }
        await refreshRoutingStrategy()
    }

    /// The store polls far more often than the key is checked, so it reports what it sees.
    func noteProxyVersion(_ version: String?) {
        if let version, version != proxyVersion { proxyVersion = version }
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

    /// Only ever from the panel's Start button: Ebb never starts the proxy on its own.
    /// Returns once `brew services` has handed the service to launchd, or failed.
    func startProxy() async {
        guard let launch = install.launch, startState != .starting else { return }
        startState = .starting
        diagnostics.record("Starting the proxy with brew services")
        if let failure = await Self.run(launch.executable, launch.arguments) {
            diagnostics.record("brew services failed: \(failure)")
            startState = .failed(failure)
        } else {
            startState = .idle
        }
    }

    /// `brew services` normally takes a second or two; a hung one is stopped after this.
    nonisolated private static let startTimeout: TimeInterval = 30

    /// The last line `brew` printed when it failed, else `nil`. Off the main actor, so the panel
    /// keeps drawing "Starting…" meanwhile.
    nonisolated private static func run(_ executable: String, _ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let deadline = Date.now + startTimeout
            while process.isRunning, Date.now < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return "brew didn't finish within \(Int(startTimeout)) seconds"
            }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus != 0 else { return nil }
            let line = text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return line.isEmpty ? "brew exited with status \(process.terminationStatus)" : String(line.prefix(120))
        }.value
    }
}
