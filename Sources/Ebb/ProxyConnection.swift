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
    /// Goes up each time the proxy accepts the key in a check, so the store resumes a key it paused.
    @ObservationIgnored private(set) var keyAcceptances = 0
    /// `nil` until read, or when the proxy can't be asked.
    private(set) var routingStrategy: String?
    private(set) var startState: StartState = .idle
    /// From the `X-Cpa-Version` header of the last answer, a refusal included.
    private(set) var proxyVersion: String?
    /// Found at launch, and again while the setup steps show: whether the Start button can do anything.
    private(set) var install = ProxyInstall.detect { FileManager.default.fileExists(atPath: $0) }
    /// Whether anything answered at `baseURL`; asked only for the setup steps, `nil` until then.
    private(set) var answers: Bool?
    /// A `cliproxyapi` on disk, however installed; looked for only while the setup steps show.
    private(set) var hasBinary = false
    /// From the config file: whether it sets a management secret-key; `nil` without one.
    private(set) var managementKeyIsSet: Bool?
    /// Shared with the store: one log for everything Copy Diagnostics reports.
    let diagnostics: DiagnosticLog

    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var key: ManagementKey?
    /// A key read from the logins folder, saved only once the proxy accepts it.
    @ObservationIgnored private var unsavedKey: ManagementKey?
    /// A logins-folder key the proxy refused, never tried again: each refusal counts toward
    /// CLIProxyAPI's 30-minute lockout of this Mac. A changed file is tried afresh.
    @ObservationIgnored private var refusedImport: ManagementKey?
    @ObservationIgnored private var isTesting = false
    @ObservationIgnored private let client = ProxyClient()
    @ObservationIgnored private let keyFile = ManagementKeyFile(url: EbbPaths.managementKeyFile)

    init(diagnostics: DiagnosticLog = DiagnosticLog()) {
        self.diagnostics = diagnostics
        discover()
        // Checked again on every launch: a value written behind Settings' back gets no exception.
        switch UserDefaults.standard.string(forKey: Self.managementURLKey).map({ ManagementURL.validate($0) }) {
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
            loadKey()
        }
        keyState = key == nil ? .missing : .checking
    }

    private func loadKey() {
        var loaded = keyFile.load(importingFrom: UserDefaults.standard.bool(forKey: Self.forgotKeyKey) ? nil : localAuthDirectory)
        if loaded?.origin == .loginsFolder, loaded?.key == refusedImport { loaded = nil }
        key = loaded?.key
        unsavedKey = loaded?.origin == .loginsFolder ? loaded?.key : nil
    }

    /// Ebb saves a key only once the proxy accepts it, so a saved one means setup was done before.
    var hasSavedKey: Bool {
        key != nil && unsavedKey == nil
    }

    var keyCheck: ProxySetup.KeyCheck {
        switch keyState {
        case .missing: .none
        case .checking: .checking
        case .valid: .accepted
        case .rejected: .refused
        case .unreachable: .unanswered
        }
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
        let found = candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
        let text = found.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let parsed = text.map(ProxyConfig.parse) ?? .defaults
        let keyIsSet = text.map(ProxyConfig.hasManagementKey)
        // Called every few seconds while the setup steps show, so only a change is published.
        if found != configFile { configFile = found }
        if parsed != config { config = parsed }
        if keyIsSet != managementKeyIsSet { managementKeyIsSet = keyIsSet }
    }

    /// For the setup steps, while they show: looks again for an install, a config and the logins
    /// folder's key file, which a fresh install brings, then asks the address whether anything answers.
    func lookForProxy() async {
        let found = ProxyInstall.detect { FileManager.default.fileExists(atPath: $0) }
        if found != install { install = found }
        let binary = ProxyInstall.binary(path: ProcessInfo.processInfo.environment["PATH"], home: EbbPaths.home) {
            FileManager.default.isExecutableFile(atPath: $0)
        } != nil
        if binary != hasBinary { hasBinary = binary }
        let hadManagementKey = managementKeyIsSet
        discover()
        if key == nil, keyState != .checking {
            loadKey()
            if key != nil { await test() }
        }
        let answered = await client.answers(baseURL)
        let cameUp = answered && answers != true
        if cameUp, ManagementURL.needsPeerCheck(baseURL), await !client.provesCLIProxyAPI(baseURL) {
            diagnostics.record("Something answers at the proxy's plain-http address without CLIProxyAPI's headers (7.3.4 or later sends them), so the key isn't sent there")
        }
        if answered != answers { answers = answered }
        // A key checked while the proxy was down, or before its management API was turned on, is checked again.
        if keyState == .unreachable, cameUp || managementKeyIsSet != hadManagementKey { await test() }
    }

    /// Checks the key against the live proxy and keeps it only if accepted.
    func save(key newKey: String) async {
        guard let newKey = ManagementKey(newKey) else { return }
        keyState = .checking
        let result = await client.check(ProxyEndpoint(baseURL: baseURL, key: newKey))
        noteProxyVersion(result.version)
        diagnostics.record("Key entered: \(result.check)")
        switch result.check {
        case .valid:
            keyAcceptances += 1
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

    /// A poll saw the proxy refuse the saved key, so Settings and the setup steps stop calling it valid.
    func noteKeyRefused() {
        if keyState == .valid { keyState = .rejected }
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
        // Settings may ask while a check is already out; one answer serves both.
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
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
        if keyState == .rejected, let unsavedKey {
            refusedImport = unsavedKey
            key = nil
            self.unsavedKey = nil
        }
        guard keyState == .valid else { return }
        keyAcceptances += 1
        if let unsavedKey, (try? keyFile.save(unsavedKey)) != nil { self.unsavedKey = nil }
        await refreshRoutingStrategy()
    }

    /// The store polls far more often than the key is checked, so it reports what it sees.
    func noteProxyVersion(_ version: String?) {
        if let version, version != proxyVersion { proxyVersion = version }
    }

    func refreshRoutingStrategy() async {
        guard !isDemo else { return }
        routingStrategy = if let endpoint { await client.routingStrategy(endpoint) } else { nil }
    }

    /// `--demo`: looks connected to a proxy on weighted round robin, with no key and no network.
    func showDemoConnection() {
        isDemo = true
        keyState = .valid
        routingStrategy = ProxyClient.weightedRoundRobin
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
