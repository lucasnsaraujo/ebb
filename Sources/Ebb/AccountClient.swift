import EbbCore
import Foundation

enum AccountFetch<Value> {
    /// `cacheData` is what goes to the cache file.
    case success(Value, cacheData: Data)
    case failed(status: Int?, retryAfter: TimeInterval?)

    var isAuthFailure: Bool {
        if case let .failed(status, _) = self { status == 401 || status == 403 } else { false }
    }
}

/// Asks an account's provider directly, for accounts the proxy has no fresh headers for.
struct AccountClient {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    func fetchUsage(_ account: ProxyAccount) async -> AccountFetch<[UsageLimit]> {
        await fetch(account.provider.usageRequest(accessToken: account.accessToken)) { data in
            account.provider.parseUsage(data).map { ($0, UsageLimit.encodeList($0)) }
        }
    }

    /// The cache keeps only the plan, not the account's personal details.
    func fetchPlan(_ account: ProxyAccount) async -> AccountFetch<PlanProfile> {
        await fetch(account.provider.planRequest(accessToken: account.accessToken)) { data in
            guard let profile = account.provider.parsePlan(data), let cacheData = try? JSONEncoder().encode(profile) else { return nil }
            return (profile, cacheData)
        }
    }

    private func fetch<Value>(_ request: URLRequest, parse: (Data) -> (Value, Data)?) async -> AccountFetch<Value> {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed(status: nil, retryAfter: nil) }

        guard http.statusCode == 200 else {
            let retryAfter = Backoff.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: .now)
            return .failed(status: http.statusCode, retryAfter: retryAfter)
        }
        guard let (value, cacheData) = parse(data) else { return .failed(status: http.statusCode, retryAfter: nil) }
        return .success(value, cacheData: cacheData)
    }
}
