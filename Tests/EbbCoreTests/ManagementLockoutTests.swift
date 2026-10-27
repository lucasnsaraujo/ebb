import Foundation
import Testing
@testable import EbbCore

@Suite struct ManagementLockoutTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_040_000)
    private let saved = ManagementKey("mgmt-old-0123456789")!
    private let replacement = ManagementKey("mgmt-new-9876543210")!

    @Test func aRefusedKeyIsNotTriedAgainBeforeTheProxysLockoutWouldHaveEnded() {
        var lockout = ManagementLockout()
        lockout.noteRefusal(of: saved, message: "invalid management key", now: t0)
        #expect(!lockout.allowsRequest(with: saved, now: t0 + 30))
        #expect(!lockout.allowsRequest(with: saved, now: t0 + 30 * 60))
        #expect(lockout.allowsRequest(with: saved, now: t0 + 31 * 60 + 1))
    }

    @Test func aNewKeyIsTriedAtOnce() {
        var lockout = ManagementLockout()
        lockout.noteRefusal(of: saved, message: "invalid management key", now: t0)
        #expect(lockout.allowsRequest(with: replacement, now: t0 + 1))
    }

    @Test func aBanWaitsForTheTimeTheProxyNames() {
        var lockout = ManagementLockout()
        lockout.noteRefusal(of: saved, message: "IP banned due to too many failed attempts. Try again in 12m30s", now: t0)
        #expect(!lockout.allowsRequest(with: saved, now: t0 + 12 * 60 + 30))
        #expect(lockout.allowsRequest(with: saved, now: t0 + 13 * 60 + 31))
        #expect(lockout.isBanned(now: t0 + 60))
    }

    @Test func anAcceptedKeyLiftsThePause() {
        var lockout = ManagementLockout()
        lockout.noteRefusal(of: saved, message: "", now: t0)
        lockout.noteAccepted()
        #expect(lockout.allowsRequest(with: saved, now: t0 + 1))
        #expect(!lockout.isBanned(now: t0 + 1))
    }

    @Test func goDurationsInTheBanMessageParse() {
        let parsed = ManagementLockout.remainingBan(in: "Try again in 29m58s")
        #expect(parsed == 1798, "\(String(describing: parsed))")
        #expect(ManagementLockout.remainingBan(in: "Try again in 1h0m0s") == 3600)
        #expect(ManagementLockout.remainingBan(in: "Try again in 45s") == 45)
        #expect(ManagementLockout.remainingBan(in: "invalid management key") == nil)
    }
}
