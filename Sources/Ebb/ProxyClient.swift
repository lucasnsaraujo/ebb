import EbbCore
import Foundation

/// Where to reach CLIProxyAPI's management API, and the key it accepts.
struct ProxyEndpoint: Sendable {
    let baseURL: URL
    let key: String
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
    func check(_ endpoint: ProxyEndpoint) async -> KeyCheck {
        guard let (_, response) = try? await session.data(for: request("config", endpoint, method: "GET")),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .unreachable }
        switch status {
        case 200: return .valid
        case 401, 403: return .rejected
        default: return .unreachable
        }
    }

    /// `nil` when the proxy isn't running or refuses the key.
    func authFiles(_ endpoint: ProxyEndpoint) async -> [ProxyAuthFile]? {
        guard let data = await get("auth-files", endpoint) else { return nil }
        return ProxyAuthFile.parseList(data)
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
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        return request
    }
}
