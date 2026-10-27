import EbbCore
import Foundation
import Testing
@testable import Ebb

/// The budget run is only as honest as its stand-in: if Ebb stopped understanding these answers,
/// the run would count a store with nothing to do and pass.
@Suite(.serialized) struct StandInProxyTests {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandInProxy.self]
        return URLSession(configuration: configuration)
    }()

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8317/v0/management/\(path)")!)
        request.httpMethod = method
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func listsTwoBusyCodexLoginsAndAnIdleOne() async throws {
        let (status, data) = try await call("auth-files")

        #expect(status == 200)
        let files = try #require(ProxyAuthFile.parseList(data))
        #expect(files.map(\.provider) == ["codex", "codex", "codex"])
        #expect(files.map { $0.quota != nil } == [true, true, false])
        #expect(files.allSatisfy { $0.authIndex != nil && $0.planName != nil })
        #expect(files.compactMap(\.quota).allSatisfy { ReadingChoice.hasFreshSignals($0, now: .now) })
    }

    @Test func answersTheIdleLoginsUsageCallWithLimitsTheStoreCanRead() async throws {
        let idle = try #require(ProxyAuthFile.parseList(try await call("auth-files").data)?.last)
        let usageCall = try #require(CodexProvider().usageCall(for: idle))

        let (status, data) = try await call("api-call", method: "POST", body: ["auth_index": usageCall.authIndex])

        guard case let .reading(reading) = CallOutcome.read(proxyStatus: status, body: data, provider: CodexProvider(), now: .now) else {
            Issue.record("the usage call wasn't read as a reading")
            return
        }
        #expect(reading.limits?.map(\.kind) == [.session, .weeklyAll])
    }

    @Test func remembersTheWeightItWasGivenSoEbbSetsEachOnce() async throws {
        let (status, _) = try await call("auth-files/fields", method: "PATCH", body: ["name": "codex-pro.json", "weight": 321])

        #expect(status == 200)
        let files = try #require(ProxyAuthFile.parseList(try await call("auth-files").data))
        #expect(files.first { $0.name == "codex-pro.json" }?.weight == 321)
    }

    @Test func tellsEbbItsKeyIsGoodAndRoutingIsWeighted() async throws {
        #expect(try await call("config").status == 200)
        let strategy = try JSONSerialization.jsonObject(with: await call("routing/strategy").data) as? [String: String]
        #expect(strategy?["strategy"] == ProxyClient.weightedRoundRobin)
    }
}
