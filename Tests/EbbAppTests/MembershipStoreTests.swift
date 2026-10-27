import EbbCore
import Foundation
import Testing
@testable import Ebb

/// Drives the real `PoolStore` in the throwaway home `ProxyOutageStoreTests` describes, so it
/// runs only when asked with `EBB_APP_TESTS=1`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EBB_APP_TESTS"] == "1")) struct MembershipStoreTests {
    private func makeStore() throws -> PoolStore {
        let home = "/tmp/ebbhome"
        try #require(ProcessInfo.processInfo.environment["CLIPROXY_CONFIG"] == "\(home)/.cli-proxy-api/config.yaml")
        try #require([EbbPaths.home, EbbPaths.cacheDirectory, EbbPaths.applicationSupport].allSatisfy { $0.path.hasPrefix(home) })
        let auth = EbbPaths.home.appending(path: "auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: EbbPaths.home.appending(path: ".cli-proxy-api"), withIntermediateDirectories: true)
        try "port: 48317\nauth-dir: \(auth.path)\n".write(to: EbbPaths.home.appending(path: ".cli-proxy-api/config.yaml"), atomically: true, encoding: .utf8)
        return PoolStore(connection: ProxyConnection(), savesStatus: false)
    }

    /// A Claude login is known by email on this Mac and by file name through a remote proxy, so
    /// a baseline from one connection would announce every login of the next.
    @Test func aConnectionChangeStartsTheBaselineOver() throws {
        var tracker = MembershipTracker()
        let roster = PoolRoster(pool: "claude", title: "Claude", present: ["a@example.com"], counted: [PoolRoster.Account(id: "a@example.com", plan: "Max 5x")])
        #expect(tracker.alerts(rosters: [roster]).isEmpty)
        #expect(tracker != MembershipTracker())
        UserDefaults.standard.set(try JSONEncoder().encode(tracker), forKey: PoolStore.membershipKey)
        let store = try makeStore()

        store.connectionDidChange()

        let saved = try #require(UserDefaults.standard.data(forKey: PoolStore.membershipKey))
        #expect(try JSONDecoder().decode(MembershipTracker.self, from: saved) == MembershipTracker())
    }
}
