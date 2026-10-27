import Foundation

/// The panel's first-run steps, shown in place of the pool until CLIProxyAPI runs on this Mac and
/// accepts a management key: install or start it, sign an account in, enter the key.
/// Ebb only looks; it never writes the proxy's config or its logins.
public struct ProxySetup: Sendable, Equatable {
    public enum Proxy: Sendable, Equatable {
        /// Not asked yet.
        case looking
        case notInstalled
        /// Installed but not answering: `brew services` starts a Homebrew install; any other gets its command.
        case stopped(ProxyInstall)
        case running
    }

    public enum Key: Sendable, Equatable {
        /// The proxy isn't running, so no key can be checked yet.
        case waiting
        /// The config has no secret-key, so the proxy's management API is off.
        case managementOff
        case needed
        case checking
        case refused
    }

    /// The management key as last checked against the proxy.
    public enum KeyCheck: Sendable {
        case none, checking, accepted, refused
        /// Checked, and the proxy didn't answer.
        case unanswered
    }

    public struct Facts: Sendable {
        /// Whether anything answered at the proxy's address; `nil` before the first try.
        public var answers: Bool?
        public var install: ProxyInstall
        /// A `cliproxyapi` found on disk, however it was installed.
        public var hasBinary: Bool
        public var keyCheck: KeyCheck
        /// From the config file: `false` when its secret-key is empty; `nil` without a config file.
        public var managementKeyIsSet: Bool?
        /// Ebb saves a key only once the proxy accepts it, so a saved key means setup was done before.
        public var hasSavedKey: Bool
        public var isRemote: Bool
        /// Logins Ebb already reads without a key.
        public var hasLogins: Bool
        /// The user chose to go on without a key.
        public var isSkipped: Bool

        public init(answers: Bool?, install: ProxyInstall, hasBinary: Bool, keyCheck: KeyCheck, managementKeyIsSet: Bool?, hasSavedKey: Bool, isRemote: Bool, hasLogins: Bool, isSkipped: Bool) {
            self.answers = answers
            self.install = install
            self.hasBinary = hasBinary
            self.keyCheck = keyCheck
            self.managementKeyIsSet = managementKeyIsSet
            self.hasSavedKey = hasSavedKey
            self.isRemote = isRemote
            self.hasLogins = hasLogins
            self.isSkipped = isSkipped
        }
    }

    public var proxy: Proxy
    public var key: Key
    public var hasLogins: Bool

    public init(proxy: Proxy, key: Key, hasLogins: Bool) {
        self.proxy = proxy
        self.key = key
        self.hasLogins = hasLogins
    }

    public static func needed(_ facts: Facts) -> ProxySetup? {
        if case .accepted = facts.keyCheck { return nil }
        if facts.hasSavedKey || facts.isRemote { return nil }
        if facts.isSkipped && facts.hasLogins { return nil }
        let proxy = proxy(facts)
        return ProxySetup(proxy: proxy, key: proxy == .running ? key(facts) : .waiting, hasLogins: facts.hasLogins)
    }

    /// Providers CLIProxyAPI signs in with its own `-<name>-login` flag, in the order offered.
    public static let loginProviders = ["claude", "codex", "antigravity", "kimi", "devin", "meta"]

    /// CLIProxyAPI's own sign-in, which opens the provider's page and saves the login in the
    /// logins folder. A Homebrew build knows its config; any other copy is pointed at it.
    public static func loginCommand(provider: String, install: ProxyInstall, configFile: String?) -> String? {
        guard loginProviders.contains(provider) else { return nil }
        let base = switch install {
        case .homebrew: ProxyInstall.formula
        case .other: install.command(configFile: configFile)
        }
        return "\(base) -\(provider)-login"
    }

    private static func key(_ facts: Facts) -> Key {
        switch facts.keyCheck {
        case .refused: .refused
        case .checking: .checking
        case .unanswered: facts.managementKeyIsSet == true ? .needed : .managementOff
        case .none, .accepted: facts.managementKeyIsSet == false ? .managementOff : .needed
        }
    }

    private static func proxy(_ facts: Facts) -> Proxy {
        switch facts.answers {
        case nil: .looking
        case true?: .running
        case false?:
            if case .homebrew = facts.install { .stopped(facts.install) } else if facts.hasBinary { .stopped(.other) } else { .notInstalled }
        }
    }
}
