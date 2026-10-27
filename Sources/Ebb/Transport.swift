import Foundation

/// Every URLSession Ebb sends requests through comes from here, so a budget run can swap the
/// network for `StandInProxy` in one place.
enum Transport {
    static func session(timeout: TimeInterval, maxConnectionsPerHost: Int? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        if let maxConnectionsPerHost { configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost }
        if Budget.isRecording { configuration.protocolClasses = [StandInProxy.self] }
        return URLSession(configuration: configuration)
    }

    /// The providers' public status pages.
    static let statusPages: URLSession = Budget.isRecording ? session(timeout: 15) : .shared
}
