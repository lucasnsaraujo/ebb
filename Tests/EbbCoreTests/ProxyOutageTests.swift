import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct ProxyOutageTests {
    private let homebrew = ProxyInstall.homebrew(prefix: "/opt/homebrew")
    private let config = "/opt/homebrew/etc/cliproxyapi.conf"

    private func advice(_ failure: ProxyOutage.Failure?, isRemote: Bool = false, install: ProxyInstall = .other) -> ProxyOutage.Advice {
        ProxyOutage.advice(failure: failure, isRemote: isRemote, host: "nas.local", install: install, configFile: config)
    }

    /// Before the first poll, and right after the address changes, nothing is known yet.
    @Test func nothingIsSaidUntilAPollActuallyFailed() {
        #expect(advice(nil) == .none)
        #expect(advice(nil, isRemote: true, install: homebrew) == .none)
    }

    @Test func aRefusedKeyPointsAtSettingsWhereverTheProxyIs() {
        #expect(advice(.refused, install: homebrew) == .keyRefused)
        #expect(advice(.refused, isRemote: true) == .keyRefused)
    }

    @Test func aLocalHomebrewProxyCanBeStartedFromThePanel() {
        #expect(advice(.unreachable, install: homebrew) == .start)
    }

    @Test func aLocalProxyInstalledAnotherWayGetsTheCommandToRun() {
        #expect(advice(.unreachable) == .command("cliproxyapi -config /opt/homebrew/etc/cliproxyapi.conf"))
    }

    /// Starting a local proxy would not bring back the remote one, and could launch an unrelated copy.
    @Test func aRemoteProxyIsNeverStartedFromThisMac() {
        #expect(advice(.unreachable, isRemote: true, install: homebrew) == .remoteUnreachable(host: "nas.local"))
        #expect(advice(.unreachable, isRemote: true) == .remoteUnreachable(host: "nas.local"))
    }
}
