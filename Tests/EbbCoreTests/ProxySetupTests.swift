import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct ProxySetupTests {
    private let homebrew = ProxyInstall.homebrew(prefix: "/opt/homebrew")

    private func setup(
        answers: Bool? = true, install: ProxyInstall = .other, hasBinary: Bool = false, key: ProxySetup.KeyCheck = .none,
        managementKeyIsSet: Bool? = true, hasSavedKey: Bool = false, isRemote: Bool = false, hasLogins: Bool = false, isSkipped: Bool = false
    ) -> ProxySetup? {
        ProxySetup.needed(ProxySetup.Facts(
            answers: answers, install: install, hasBinary: hasBinary, keyCheck: key, managementKeyIsSet: managementKeyIsSet,
            hasSavedKey: hasSavedKey, isRemote: isRemote, hasLogins: hasLogins, isSkipped: isSkipped
        ))
    }

    @Test func nothingIsLeftToSetUpOnceTheProxyAcceptsAKey() {
        #expect(setup(key: .accepted) == nil)
    }

    /// A proxy that stopped, or refuses a key it once took, is the outage notice's business.
    @Test func aKeyAcceptedBeforeMeansSetupIsNeverShownAgain() {
        #expect(setup(answers: false, hasSavedKey: true) == nil)
        #expect(setup(key: .refused, hasSavedKey: true) == nil)
    }

    /// Someone who typed in a remote address has set the proxy up already, and nothing here could install or start it.
    @Test func aRemoteProxyNeverGetsSetupSteps() {
        #expect(setup(answers: false, isRemote: true) == nil)
        #expect(setup(isRemote: true) == nil)
    }

    @Test func goingOnWithoutAKeyHidesSetupOnlyWhileSomeLoginCanBeRead() {
        #expect(setup(hasLogins: true, isSkipped: true) == nil)
        #expect(setup(hasLogins: false, isSkipped: true) != nil)
        #expect(setup(hasLogins: true, isSkipped: false) != nil)
    }

    @Test func untilTheAddressIsTriedNobodyKnowsWhetherTheProxyRuns() {
        #expect(setup(answers: nil, install: homebrew)?.proxy == .looking)
    }

    @Test func aProxyThatDoesNotAnswerIsStartedFromHomebrewOrFromTheBinaryFound() {
        #expect(setup(answers: false, install: homebrew)?.proxy == .stopped(homebrew))
        #expect(setup(answers: false, hasBinary: true)?.proxy == .stopped(.other))
    }

    @Test func withoutHomebrewsFormulaOrABinaryTheProxyIsNotInstalled() {
        #expect(setup(answers: false)?.proxy == .notInstalled)
    }

    /// Whatever answers on the address is the proxy, however it was installed.
    @Test func anAnsweringProxyRunsWithoutAnyInstallFound() {
        #expect(setup(answers: true)?.proxy == .running)
    }

    @Test func noKeyCanBeCheckedUntilTheProxyRuns() {
        #expect(setup(answers: nil)?.key == .waiting)
        #expect(setup(answers: false, install: homebrew, key: .refused)?.key == .waiting)
    }

    @Test func aRunningProxyAsksForTheKeyAndSaysWhatBecameOfIt() {
        #expect(setup(key: .none)?.key == .needed)
        #expect(setup(key: .checking)?.key == .checking)
        #expect(setup(key: .refused)?.key == .refused)
    }

    /// CLIProxyAPI turns its management API off, answering 404, while the config's secret-key is empty.
    @Test func anEmptySecretKeyOrAManagementAPIThatDoesNotAnswerMeansManagementIsOff() {
        #expect(setup(key: .none, managementKeyIsSet: false)?.key == .managementOff)
        #expect(setup(key: .unanswered, managementKeyIsSet: nil)?.key == .managementOff)
        #expect(setup(key: .none, managementKeyIsSet: nil)?.key == .needed)
    }

    /// With a secret-key in the config the management API is on, so no answer was a timeout or a crash: ask again.
    @Test func aKeyCheckNobodyAnsweredIsAskedAgainWhenTheConfigSetsAKey() {
        #expect(setup(key: .unanswered, managementKeyIsSet: true)?.key == .needed)
    }

    /// A key set through the environment never shows in the config, so the proxy's refusal is the better word.
    @Test func aRefusalOutranksAnEmptySecretKeyInTheConfig() {
        #expect(setup(key: .refused, managementKeyIsSet: false)?.key == .refused)
    }

    /// Homebrew builds CLIProxyAPI with its own config path baked in; any other copy has to be told.
    @Test func theSignInCommandNamesTheConfigOnlyOutsideHomebrew() {
        #expect(ProxySetup.loginCommand(provider: "claude", install: homebrew, configFile: "/opt/homebrew/etc/cliproxyapi.conf") == "cliproxyapi -claude-login")
        #expect(ProxySetup.loginCommand(provider: "codex", install: .other, configFile: "/Users/me/My Configs/cpa.yaml") == "cliproxyapi -config '/Users/me/My Configs/cpa.yaml' -codex-login")
        #expect(ProxySetup.loginCommand(provider: "claude", install: .other, configFile: nil) == "cliproxyapi -claude-login")
    }

    /// The flags CLIProxyAPI's `cmd/server/main.go` defines; a provider without one gets no command.
    @Test func everyProviderOfferedHasALoginFlagTheProxyDefines() {
        let defined: Set = ["claude-login", "codex-login", "antigravity-login", "kimi-login", "devin-login", "meta-login"]
        for provider in ProxySetup.loginProviders {
            let flag = ProxySetup.loginCommand(provider: provider, install: homebrew, configFile: nil)?.split(separator: " ").last.map { String($0.dropFirst()) }
            #expect(flag.map(defined.contains) == true, "\(provider)")
        }
        #expect(ProxySetup.loginCommand(provider: "xai-health", install: homebrew, configFile: nil) == nil)
    }
}
