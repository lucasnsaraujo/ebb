import EbbCore
import Foundation
import Testing
@testable import Ebb

/// Drives the real `PoolStore` against `FakeProxy`. The store reads Ebb's folders from the
/// home directory, so this runs only when asked, in a throwaway home:
///
///     rm -rf /tmp/ebbhome && mkdir -p /tmp/ebbhome && EBB_APP_TESTS=1 HOME=/tmp/ebbhome CFFIXED_USER_HOME=/tmp/ebbhome \
///       CLIPROXY_CONFIG=/tmp/ebbhome/.cli-proxy-api/config.yaml swift test --disable-keychain --filter EbbAppTests
///
/// It refuses to run if any of Ebb's paths would land outside that home.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EBB_APP_TESTS"] == "1")) struct ProxyOutageStoreTests {
    private static let accountFile = "claude-1-a@example.com.json"

    /// Without `hasLogin` the folder holds only the key, so the store never asks a provider for anything.
    private func makeStore(proxy: FakeProxy, hasLogin: Bool = true) throws -> PoolStore {
        let home = "/tmp/ebbhome"
        try #require(ProcessInfo.processInfo.environment["CLIPROXY_CONFIG"] == "\(home)/.cli-proxy-api/config.yaml")
        try #require([EbbPaths.home, EbbPaths.cacheDirectory, EbbPaths.applicationSupport].allSatisfy { $0.path.hasPrefix(home) })

        let fileManager = FileManager.default
        let auth = EbbPaths.home.appending(path: "auth")
        try fileManager.createDirectory(at: auth, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: EbbPaths.home.appending(path: ".cli-proxy-api"), withIntermediateDirectories: true)
        try "port: \(proxy.port)\nauth-dir: \(auth.path)\n".write(to: EbbPaths.home.appending(path: ".cli-proxy-api/config.yaml"), atomically: true, encoding: .utf8)
        try "fake-key".write(to: auth.appending(path: ".management-key"), atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: auth.appending(path: Self.accountFile))
        if hasLogin {
            try #"{"type":"claude","email":"a@example.com","access_token":"fake"}"#.write(to: auth.appending(path: Self.accountFile), atomically: true, encoding: .utf8)
            EbbPaths.writeCache(try JSONEncoder().encode(PlanProfile(plan: .paid(weight: PlanWeight(5)), tier: "default_claude_max_5x")), to: EbbPaths.planCache(for: "a@example.com"))
        }
        return PoolStore(connection: ProxyConnection(), savesStatus: false)
    }

    /// Refreshes from the panel, waiting for the one in flight to end.
    private func refresh(_ store: PoolStore) async throws -> RefreshOutcome? {
        store.refreshNow()
        #expect(store.isRefreshing)
        for _ in 0..<200 where store.isRefreshing {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!store.isRefreshing)
        return store.lastRefresh
    }

    private func listing(readAt: Date) -> Data {
        let reset = Int(readAt.timeIntervalSince1970) + 3600
        return Data(#"""
        {"files":[{"name":"\#(Self.accountFile)","provider":"claude","type":"claude","email":"a@example.com","disabled":false,"weight":100,
        "quota":{"observed_at":"\#(readAt.formatted(.iso8601))","signals":{"Anthropic-Ratelimit-Unified-5h-Utilization":"0.40","Anthropic-Ratelimit-Unified-5h-Reset":"\#(reset)","Anthropic-Ratelimit-Unified-7d-Utilization":"0.20","Anthropic-Ratelimit-Unified-7d-Reset":"\#(reset + 100_000)"}}}]}
        """#.utf8)
    }

    @Test func numbersStayOnShowDimmedWhileTheProxyIsDownAndLiveAgainWhenItReturns() async throws {
        let proxy = FakeProxy(listing: listing(readAt: .now))
        try proxy.start()
        let store = try makeStore(proxy: proxy)

        await store.readProxyOnce()
        #expect(!store.isProxyUnreachable)
        #expect(store.state.summaries["claude"]?.session.freePercent == 60)
        let live = MenuBarItem(style: .standard, limit: .fiveHour, pool: store.menuBarPool(for: "claude", now: .now), now: .now)
        #expect(!live.isStale)

        proxy.stop()
        await store.readProxyOnce()
        #expect(store.isProxyUnreachable)
        #expect(store.proxyFailure == .unreachable)
        #expect(store.state.summaries["claude"]?.session.freePercent == 60)
        let down = MenuBarItem(style: .standard, limit: .fiveHour, pool: store.menuBarPool(for: "claude", now: .now), now: .now)
        #expect(down.isStale)
        #expect(down.parts.contains { if case .line = $0 { true } else { false } })

        try proxy.start()
        await store.readProxyOnce()
        #expect(!store.isProxyUnreachable)
        #expect(store.proxyFailure == nil)
        #expect(store.state.summaries["claude"]?.session.freePercent == 60)
    }

    /// The refresh button shakes only for a refresh that got nothing: a proxy that didn't answer
    /// or refused the key. One that answered ends with a checkmark.
    @Test func aRefreshFromThePanelSaysWhetherTheProxyAnswered() async throws {
        let proxy = FakeProxy(listing: listing(readAt: .now))
        let store = try makeStore(proxy: proxy, hasLogin: false)
        store.setActive(true)
        defer { store.setActive(false) }

        let down = try await refresh(store)
        #expect(down?.failed == true)
        #expect(store.proxyFailure == .unreachable)

        try proxy.start()
        let up = try await refresh(store)
        #expect(up?.failed == false)
        #expect(up != down)
        #expect(store.proxyFailure == nil)

        proxy.refusesKeys = true
        let refused = try await refresh(store)
        #expect(refused?.failed == true)
        #expect(store.proxyFailure == .refused)
        proxy.stop()
    }

    /// Five refusals lock this Mac out for 30 minutes, after which even the right key is refused.
    @Test func aRefusedKeyFromTheLoginsFolderIsNeverSentAgain() async throws {
        let proxy = FakeProxy(listing: Data(), refusesKeys: true)
        try proxy.start()
        _ = try makeStore(proxy: proxy)
        let connection = ProxyConnection()

        await connection.test()
        #expect(connection.keyState == .rejected)
        #expect(connection.endpoint == nil)
        let calls = proxy.managementCallCount
        for _ in 0..<3 { await connection.lookForProxy() }
        #expect(connection.answers == true)
        #expect(proxy.managementCallCount == calls)
    }

    /// Polls come every 30 s; resending a refused key would reach the proxy's five-strike lockout in two minutes.
    @Test func theStoreSendsARefusedKeyOnceNotOnEveryPoll() async throws {
        let proxy = FakeProxy(listing: Data(), refusesKeys: true)
        try proxy.start()
        let store = try makeStore(proxy: proxy)

        for _ in 0..<4 { await store.readProxyOnce() }
        #expect(store.proxyFailure == .refused)
        #expect(proxy.managementCallCount == 1)
    }

    /// After fixing the proxy's config, pressing Test in Settings (or re-saving the key) must not leave the pool waiting 31 min.
    @Test func aKeyTheProxyAcceptsAgainIsPolledAtOnce() async throws {
        let proxy = FakeProxy(listing: listing(readAt: .now), refusesKeys: true)
        try proxy.start()
        _ = try makeStore(proxy: proxy)
        // Made after makeStore wrote the config, so it finds the fake proxy.
        let connection = ProxyConnection()
        let store = PoolStore(connection: connection, savesStatus: false)

        await store.readProxyOnce()
        #expect(store.proxyFailure == .refused)
        proxy.refusesKeys = false
        await store.readProxyOnce()
        #expect(store.proxyFailure == .refused)
        await connection.test()
        await store.readProxyOnce()
        #expect(store.proxyFailure == nil)
        #expect(store.state.summaries["claude"]?.session.freePercent == 60)
    }
}
