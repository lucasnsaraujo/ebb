import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct ProxyInstallTests {
    private func install(existing: Set<String>) -> ProxyInstall {
        ProxyInstall.detect { existing.contains($0) }
    }

    @Test func homebrewIsFoundWhereBrewAndTheFormulaLiveTogether() {
        #expect(install(existing: ["/opt/homebrew/bin/brew", "/opt/homebrew/opt/cliproxyapi"]) == .homebrew(prefix: "/opt/homebrew"))
        #expect(install(existing: ["/usr/local/bin/brew", "/usr/local/opt/cliproxyapi"]) == .homebrew(prefix: "/usr/local"))
    }

    @Test func brewWithoutTheFormulaOrTheFormulaWithoutBrewIsNotAHomebrewInstall() {
        #expect(install(existing: ["/opt/homebrew/bin/brew"]) == .other)
        #expect(install(existing: ["/opt/homebrew/opt/cliproxyapi", "/usr/local/bin/brew"]) == .other)
        #expect(install(existing: []) == .other)
    }

    @Test func homebrewStartsThroughItsOwnBrewAsAService() throws {
        let launch = try #require(ProxyInstall.homebrew(prefix: "/opt/homebrew").launch)
        #expect(launch.executable == "/opt/homebrew/bin/brew")
        #expect(launch.arguments == ["services", "start", "cliproxyapi"])
        #expect(ProxyInstall.other.launch == nil)
    }

    @Test func theCommandToShowNamesTheConfigFileAndQuotesSpaces() {
        #expect(ProxyInstall.homebrew(prefix: "/opt/homebrew").command(configFile: nil) == "brew services start cliproxyapi")
        #expect(ProxyInstall.other.command(configFile: "/Users/me/.cli-proxy-api/config.yaml") == "cliproxyapi -config /Users/me/.cli-proxy-api/config.yaml")
        #expect(ProxyInstall.other.command(configFile: "/Users/me/My Configs/cpa.yaml") == "cliproxyapi -config '/Users/me/My Configs/cpa.yaml'")
        #expect(ProxyInstall.other.command(configFile: nil) == "cliproxyapi")
    }
}

@Suite(.hangLimit) struct ProxyBinaryTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func binary(path: String?, existing: Set<String>) -> String? {
        ProxyInstall.binary(path: path, home: home) { existing.contains($0) }
    }

    @Test func theBinaryIsFoundInAFolderOnThePath() {
        #expect(binary(path: "/usr/bin:/opt/tools/bin", existing: ["/opt/tools/bin/cliproxyapi"]) == "/opt/tools/bin/cliproxyapi")
    }

    /// An app gets a bare PATH, so the places installs usually land are looked at too.
    @Test func theUsualInstallFoldersAreLookedAtWhenThePathIsBare() {
        #expect(binary(path: "/usr/bin:/bin", existing: ["/Users/me/go/bin/cliproxyapi"]) == "/Users/me/go/bin/cliproxyapi")
        #expect(binary(path: nil, existing: ["/usr/local/bin/cliproxyapi"]) == "/usr/local/bin/cliproxyapi")
    }

    @Test func noBinaryAnywhereIsNil() {
        #expect(binary(path: "/usr/bin:/bin", existing: ["/usr/bin/brew"]) == nil)
    }
}
