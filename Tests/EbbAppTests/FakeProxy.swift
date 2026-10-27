import Foundation
import Network

/// A stand-in for CLIProxyAPI's management API on a loopback port, so the store can be driven
/// without the real proxy. `stop()` and `start()` play the proxy going down and coming back.
final class FakeProxy: @unchecked Sendable {
    private(set) var port: UInt16
    private var listener: NWListener?
    private let listing: Data
    /// Answers every management call with 401, as CLIProxyAPI does to a wrong key. Settable, to play
    /// the user fixing the proxy's config.
    var refusesKeys: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    private var refusing: Bool
    private let lock = NSLock()
    private var managementCalls = 0

    init(listing: Data, refusesKeys: Bool = false) {
        self.listing = listing
        refusing = refusesKeys
        port = UInt16.random(in: 40_000..<60_000)
    }

    /// Management calls so far; each refused one counts toward CLIProxyAPI's lockout.
    var managementCallCount: Int {
        lock.withLock { managementCalls }
    }

    private func countManagementCall() {
        lock.withLock { managementCalls += 1 }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let listing = listing
        listener.newConnectionHandler = { [weak self] connection in
            let proxy = self
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let isManagement = request.split(separator: " ").dropFirst().first?.hasPrefix("/v0/management/") == true
                if isManagement { proxy?.countManagementCall() }
                let isListing = request.hasPrefix("GET /v0/management/auth-files")
                let isRefusing = proxy?.refusesKeys ?? false
                let status = isManagement && isRefusing ? 401 : isListing || request.hasPrefix("GET /v0/management/config") ? 200 : 404
                let payload = status == 200 ? listing : Data()
                let head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        self.listener = listener
        Thread.sleep(forTimeInterval: 0.3)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Thread.sleep(forTimeInterval: 0.3)
    }
}
