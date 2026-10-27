import EbbCore
import Foundation

/// Where to reach CLIProxyAPI's management API, and the key it accepts.
struct ProxyEndpoint: Sendable {
    let baseURL: URL
    let key: ManagementKey
}

/// CLIProxyAPI's management API. Free to call: no provider traffic. Changes go
/// through it rather than the auth files, so they never race the proxy's own writes.
struct ProxyClient {
    enum KeyCheck: Sendable {
        case valid, rejected, unreachable
    }

    static let weightedRoundRobin = "weighted-round-robin"

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    /// Asks for the proxy's config, which only a valid key may read.
    func check(_ endpoint: ProxyEndpoint) async -> (check: KeyCheck, version: String?) {
        guard let (_, response) = try? await session.data(for: request("config", endpoint, method: "GET")),
              let http = response as? HTTPURLResponse
        else { return (.unreachable, nil) }
        let version = Self.version(of: http)
        switch http.statusCode {
        case 200: return (.valid, version)
        case 401, 403: return (.rejected, version)
        default: return (.unreachable, version)
        }
    }

    /// Whether anything answers at the proxy's address. Asks `/healthz`, outside the management API,
    /// since every keyless management call counts toward CLIProxyAPI's lockout of this Mac.
    func answers(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "healthz"), timeoutInterval: 2)
        request.httpMethod = "HEAD"
        return (try? await session.data(for: request))?.1 is HTTPURLResponse
    }

    /// A poll of the listing: the logins, a refused key, or no answer at all. Every answer
    /// names the proxy's version, a refusal included.
    enum Listing {
        case files([ProxyAuthFile], version: String?)
        case refused(version: String?)
        case unreachable
    }

    func authFiles(_ endpoint: ProxyEndpoint) async -> Listing {
        guard let (data, response) = try? await session.data(for: request("auth-files", endpoint, method: "GET")),
              let http = response as? HTTPURLResponse
        else { return .unreachable }
        let version = Self.version(of: http)
        switch http.statusCode {
        case 200: return ProxyAuthFile.parseList(data).map { .files($0, version: version) } ?? .unreachable
        case 401, 403: return .refused(version: version)
        default: return .unreachable
        }
    }

    private static func version(of response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "X-Cpa-Version").flatMap { $0.isEmpty ? nil : $0 }
    }

    func routingStrategy(_ endpoint: ProxyEndpoint) async -> String? {
        guard let data = await get("routing/strategy", endpoint),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return body["strategy"] as? String
    }

    func setRoutingStrategy(_ strategy: String, _ endpoint: ProxyEndpoint) async -> Bool {
        await send("routing/strategy", endpoint, method: "PUT", body: ["value": strategy])
    }

    /// Sets the share of new sessions the weighted round robin gives this login.
    func setWeight(_ weight: Int, for name: String, _ endpoint: ProxyEndpoint) async -> Bool {
        await send("auth-files/fields", endpoint, method: "PATCH", body: ["name": name, "weight": weight])
    }

    func setDisabled(_ isDisabled: Bool, for name: String, _ endpoint: ProxyEndpoint) async -> Bool {
        await send("auth-files/status", endpoint, method: "PATCH", body: ["name": name, "disabled": isDisabled])
    }

    /// Sends a request on a login's behalf; the proxy fills in its token. The status is the
    /// proxy's own: 200 wraps the provider's answer, 400 means it had no token to send.
    func apiCall(_ call: ProxyAPICall, _ endpoint: ProxyEndpoint) async -> (status: Int, body: Data)? {
        var request = request("api-call", endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = call.body()
        request.timeoutInterval = 30
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        return (status, data)
    }

    private func get(_ path: String, _ endpoint: ProxyEndpoint) async -> Data? {
        guard let (data, response) = try? await session.data(for: request(path, endpoint, method: "GET")),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private func send(_ path: String, _ endpoint: ProxyEndpoint, method: String, body: [String: Any]) async -> Bool {
        var request = request(path, endpoint, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return false }
        return (200..<300).contains(status)
    }

    private func request(_ path: String, _ endpoint: ProxyEndpoint, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "v0/management/\(path)"))
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.key.value)", forHTTPHeaderField: "Authorization")
        return request
    }
}
