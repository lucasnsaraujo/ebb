import EbbCore
import Foundation
import Testing
@testable import Ebb

/// The Claude and Antigravity proxies side by side, in the throwaway home `ProxyOutageStoreTests`
/// describes, so it runs only when asked with `EBB_APP_TESTS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EBB_APP_TESTS"] == "1")) struct ProxyPoolTests {
    private let antigravityURL = URL(string: "http://127.0.0.1:48318")!

    /// A config naming a logins folder that holds a `.management-key`, as a local Claude proxy's does.
    private func makeLocalProxy() throws {
        let home = "/tmp/ebbhome"
        try #require(ProcessInfo.processInfo.environment["CLIPROXY_CONFIG"] == "\(home)/.cli-proxy-api/config.yaml")
        try #require([EbbPaths.home, EbbPaths.cacheDirectory, EbbPaths.applicationSupport].allSatisfy { $0.path.hasPrefix(home) })
        let auth = EbbPaths.home.appending(path: "auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: EbbPaths.home.appending(path: ".cli-proxy-api"), withIntermediateDirectories: true)
        try "port: 48317\nauth-dir: \(auth.path)\n".write(to: EbbPaths.home.appending(path: ".cli-proxy-api/config.yaml"), atomically: true, encoding: .utf8)
        try "fake-key".write(to: auth.appending(path: ".management-key"), atomically: true, encoding: .utf8)
    }

    @Test func theAntigravityPoolNeverTakesTheLocalProxysAddressOrKey() throws {
        try makeLocalProxy()
        let claude = ProxyConnection(pool: .claude)
        let antigravity = ProxyConnection(pool: .antigravity)

        #expect(claude.endpoint?.key.value == "fake-key")
        #expect(antigravity.endpoint == nil)
        #expect(antigravity.localAuthDirectory == nil)
    }

    @Test func theAntigravityPoolNeverSendsClaudesSavedKey() throws {
        try makeLocalProxy()
        let claudeKey = ManagementKeyFile(url: EbbPaths.managementKeyFile)
        try claudeKey.save(try #require(ManagementKey("claude-key")))
        defer { claudeKey.delete() }
        ManagementKeyFile(url: ProxyPool.antigravity.file(EbbPaths.managementKeyFile)).delete()
        let urlKey = ProxyPool.antigravity.key("managementURL")
        UserDefaults.standard.set(antigravityURL.absoluteString, forKey: urlKey)
        defer { UserDefaults.standard.removeObject(forKey: urlKey) }

        let antigravity = ProxyConnection(pool: .antigravity)

        #expect(antigravity.baseURL == antigravityURL)
        #expect(antigravity.endpoint == nil)
    }

    /// Set up in Settings while Ebb shows: no relaunch needed, and nothing ran before.
    @Test func theAntigravityStoreStartsPollingOnceItHasAnAddress() async throws {
        try makeLocalProxy()
        let keyFile = ManagementKeyFile(url: ProxyPool.antigravity.file(EbbPaths.managementKeyFile))
        try keyFile.save(try #require(ManagementKey("antigravity-key")))
        defer { keyFile.delete() }
        let proxy = FakeProxy(listing: Data(#"{"files":[]}"#.utf8))
        try proxy.start()
        defer { proxy.stop() }
        let connection = ProxyConnection(pool: .antigravity)
        let store = PoolStore(connection: connection, savesStatus: false)
        store.setActive(true)
        defer { store.setActive(false) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(proxy.managementCallCount == 0)

        connection.setManagementURL(URL(string: "http://127.0.0.1:\(proxy.port)"))
        defer { connection.setManagementURL(nil) }
        store.connectionDidChange()
        for _ in 0..<80 where store.proxyReadAt == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(store.proxyReadAt != nil)
    }

    @Test func eachPoolKeepsItsOwnAddress() throws {
        try makeLocalProxy()
        let antigravity = ProxyConnection(pool: .antigravity)
        antigravity.setManagementURL(antigravityURL)
        defer { antigravity.setManagementURL(nil) }

        #expect(ProxyConnection(pool: .antigravity).managementURL == antigravityURL)
        #expect(ProxyConnection(pool: .claude).managementURL == nil)
    }

    /// Both stores run at once, so one resetting its baseline mustn't wipe the other's.
    @Test func eachPoolKeepsItsOwnMembership() throws {
        try makeLocalProxy()
        var tracker = MembershipTracker()
        let roster = PoolRoster(pool: "claude", title: "Claude", present: ["a@example.com"], counted: [PoolRoster.Account(id: "a@example.com", plan: "Max 5x")])
        _ = tracker.alerts(rosters: [roster])
        let saved = try JSONEncoder().encode(tracker)
        UserDefaults.standard.set(saved, forKey: PoolStore.membershipKey)
        let store = PoolStore(connection: ProxyConnection(pool: .antigravity), savesStatus: false)

        store.connectionDidChange()

        #expect(UserDefaults.standard.data(forKey: PoolStore.membershipKey) == saved)
    }
}
