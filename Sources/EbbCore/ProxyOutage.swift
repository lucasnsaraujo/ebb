import Foundation

/// What the panel says, and offers, when the proxy didn't answer its last poll.
public enum ProxyOutage {
    public enum Failure: Sendable, Equatable {
        /// Nothing answered: the proxy isn't running, or can't be reached.
        case unreachable
        /// The proxy answered, but not to this key.
        case refused
    }

    public enum Advice: Sendable, Equatable {
        /// Nothing to say: the proxy answered, or hasn't been asked yet.
        case none
        case keyRefused
        /// A proxy on this Mac that isn't running, which `brew services` can start.
        case start
        /// A proxy on this Mac installed some other way: the command to run.
        case command(String)
        /// A proxy on another machine that isn't answering; nothing here can start it.
        case remoteUnreachable(host: String)
    }

    /// Only a poll that failed says anything: before the first one, nothing is known yet.
    /// A remote proxy is never started from here, since that would launch an unrelated local copy.
    public static func advice(failure: Failure?, isRemote: Bool, host: String, install: ProxyInstall, configFile: String?) -> Advice {
        switch failure {
        case nil: .none
        case .refused: .keyRefused
        case .unreachable where isRemote: .remoteUnreachable(host: host)
        case .unreachable: install.launch == nil ? .command(install.command(configFile: configFile)) : .start
        }
    }
}
