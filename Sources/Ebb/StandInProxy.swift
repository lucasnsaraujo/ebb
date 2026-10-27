import Foundation
import os

/// A budget run's network. It answers each request from inside the process as CLIProxyAPI would with
/// three Codex logins, two of them busy and one idle, and counts it; nothing leaves the machine.
/// The proxy remembers the weights it's given, as the real one does, so Ebb sets each once.
final class StandInProxy: URLProtocol {
    private static let weights = OSAllocatedUnfairLock(initialState: [String: Int]())

    private struct Login {
        var name: String
        var authIndex: String
        var plan: String
        var isBusy: Bool
    }

    private static let logins = [
        Login(name: "codex-busy.json", authIndex: "1", plan: "plus", isBusy: true),
        Login(name: "codex-pro.json", authIndex: "2", plan: "pro", isBusy: true),
        Login(name: "codex-idle.json", authIndex: "3", plan: "plus", isBusy: false),
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let management = url.path.hasPrefix("/v0/management/") ? String(url.path.dropFirst("/v0/management/".count)) : nil
        Budget.request("\(method) \(management ?? url.host() ?? url.path)")
        let (status, body) = Self.answer(method: method, management: management, host: url.host(), body: Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "X-Cpa-Version": "6.0.0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(method: String, management: String?, host: String?, body: Data) -> (Int, Data) {
        guard let management else {
            guard host?.hasPrefix("status.") == true else { return (404, Data()) }
            return (200, json(["components": [["name": "Codex", "status": "operational"], ["name": "Responses", "status": "operational"]]]))
        }
        switch (method, management) {
        case ("GET", "config"): return (200, json([:]))
        case ("GET", "routing/strategy"): return (200, json(["strategy": ProxyClient.weightedRoundRobin]))
        case ("GET", "auth-files"): return (200, json(["files": logins.map(listing)]))
        case ("PATCH", "auth-files/fields"):
            guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = fields["name"] as? String, let weight = (fields["weight"] as? NSNumber)?.intValue
            else { return (400, Data()) }
            weights.withLock { $0[name] = weight }
            return (200, json([:]))
        case ("POST", "api-call"): return (200, json(["status_code": 200, "header": [:], "body": usage()]))
        default: return (404, Data())
        }
    }

    /// Busy logins carry the quota signals of their latest response, as the proxy keeps them; the idle one has none.
    private static func listing(_ login: Login) -> [String: Any] {
        var file: [String: Any] = [
            "name": login.name, "provider": "codex", "type": "codex", "email": "\(login.name)@example.com",
            "auth_index": login.authIndex, "disabled": false, "status": "active",
            "id_token": ["plan_type": login.plan, "chatgpt_account_id": "account-\(login.authIndex)"],
        ]
        if let weight = weights.withLock({ $0[login.name] }) { file["weight"] = weight }
        if login.isBusy {
            file["quota"] = [
                "observed_at": Date.now.formatted(.iso8601),
                "signals": [
                    "X-Codex-Plan-Type": login.plan,
                    "X-Codex-Primary-Used-Percent": "22", "X-Codex-Primary-Window-Minutes": "300", "X-Codex-Primary-Reset-After-Seconds": "7200",
                    "X-Codex-Secondary-Used-Percent": "41", "X-Codex-Secondary-Window-Minutes": "10080", "X-Codex-Secondary-Reset-After-Seconds": "250000",
                ],
            ]
        }
        return file
    }

    /// What `chatgpt.com/backend-api/wham/usage` answers, as a string: the proxy wraps it.
    private static func usage() -> String {
        let now = Date.now.timeIntervalSince1970
        let window = { (used: Int, seconds: Int, resets: Double) in ["used_percent": used, "limit_window_seconds": seconds, "reset_at": Int(now + resets)] }
        let body: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": ["allowed": true, "limit_reached": false, "primary_window": window(22, 18_000, 7_200), "secondary_window": window(41, 604_800, 250_000)],
        ]
        return String(decoding: json(body), as: UTF8.self)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A body handed to a session arrives as a stream.
    private static func body(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
