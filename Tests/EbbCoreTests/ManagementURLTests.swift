import Foundation
import Testing
@testable import EbbCore

@Suite struct ManagementURLTests {
    @Test func httpsIsAlwaysFine() {
        #expect(ManagementURL.validate("https://proxy.example.com:8317") == .ok(URL(string: "https://proxy.example.com:8317")!))
        #expect(ManagementURL.validate("https://203.0.113.9") == .ok(URL(string: "https://203.0.113.9")!))
    }

    @Test func plainHttpOnAPrivateNetworkIsAllowedWithAWarning() {
        for host in ["localhost", "127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.5", "169.254.1.1", "[::1]", "[fe80::1]", "[fd12:3456::1]", "homelab.local", "nas.Local"] {
            let address = "http://\(host):8317"
            #expect(ManagementURL.validate(address) == .unencrypted(URL(string: address)!), Comment(rawValue: host))
        }
    }

    @Test func plainHttpAnywhereElseIsRefusedAskingForHttps() {
        for address in ["http://proxy.example.com:8317", "http://8.8.8.8", "http://172.32.0.1:8317", "http://[2001:db8::1]:8317", "http://homelab.locale"] {
            guard case let .refused(message) = ManagementURL.validate(address) else {
                Issue.record("\(address) was not refused")
                continue
            }
            #expect(message.contains("https"), Comment(rawValue: address))
        }
    }

    @Test func anythingThatIsNotAWebAddressIsRefused() {
        for text in ["", "   ", "proxy.example.com:8317", "ftp://proxy.example.com", "https://", "not a url"] {
            guard case .refused = ManagementURL.validate(text) else {
                Issue.record("\(text) was accepted")
                continue
            }
        }
    }

    /// The key is the credential; a user name and password in the address would only end up in Settings.
    @Test func credentialsInTheAddressAreRefused() {
        for address in ["https://user:pw@proxy.example.com:8317", "https://user@proxy.example.com", "http://admin:secret@192.168.1.5:8317"] {
            guard case let .refused(message) = ManagementURL.validate(address) else {
                Issue.record("\(address) was accepted")
                continue
            }
            #expect(message.contains("password"), Comment(rawValue: address))
            #expect(!message.contains("pw") && !message.contains("secret"), Comment(rawValue: address))
        }
    }

    @Test func theSchemeIsReadWhateverItsCase() {
        #expect(ManagementURL.validate("HTTPS://proxy.example.com:8317") == .ok(URL(string: "https://proxy.example.com:8317")!))
        #expect(ManagementURL.validate("Http://192.168.1.5:8317") == .unencrypted(URL(string: "http://192.168.1.5:8317")!))
        guard case .refused = ManagementURL.validate("HTTP://proxy.example.com") else {
            Issue.record("uppercase plain http to a public host was accepted")
            return
        }
    }

    @Test func aMappedIPv6AddressFollowsItsIPv4Rule() {
        #expect(ManagementURL.validate("http://[::ffff:192.168.1.5]:8317") == .unencrypted(URL(string: "http://[::ffff:192.168.1.5]:8317")!))
        #expect(ManagementURL.validate("http://[::ffff:c0a8:105]:8317") == .unencrypted(URL(string: "http://[::ffff:c0a8:105]:8317")!))
        for address in ["http://[::ffff:8.8.8.8]:8317", "http://[::ffff:808:808]:8317"] {
            guard case .refused = ManagementURL.validate(address) else {
                Issue.record("\(address) was accepted")
                continue
            }
        }
    }

    @Test func theAddressIsTrimmedToTheProxysBase() {
        let base = URL(string: "https://proxy.example.com:8317")!
        #expect(ManagementURL.validate(" https://proxy.example.com:8317/ \n") == .ok(base))
        #expect(ManagementURL.validate("https://proxy.example.com:8317/management.html") == .ok(base))
        #expect(ManagementURL.validate("https://proxy.example.com:8317/v0/management/") == .ok(base))
        #expect(ManagementURL.validate("https://proxy.example.com:8317/?x=1#top") == .ok(base))
        #expect(ManagementURL.validate("https://proxy.example.com/cpa/") == .ok(URL(string: "https://proxy.example.com/cpa")!))
    }

    /// A private address names whatever machine holds it on the current network, so plain http
    /// there must prove it's CLIProxyAPI before the key goes out; loopback and https needn't.
    @Test func onlyPlainHttpOffThisMacNeedsTheProxyToProveItself() {
        #expect(ManagementURL.needsPeerCheck(URL(string: "http://192.168.1.20:8317")!))
        #expect(ManagementURL.needsPeerCheck(URL(string: "http://proxy.local:8317")!))
        #expect(!ManagementURL.needsPeerCheck(URL(string: "http://127.0.0.1:8317")!))
        #expect(!ManagementURL.needsPeerCheck(URL(string: "http://localhost:8317")!))
        #expect(!ManagementURL.needsPeerCheck(URL(string: "http://[::1]:8317")!))
        #expect(!ManagementURL.needsPeerCheck(URL(string: "https://192.168.1.20:8317")!))
    }

    @Test func cliProxyAPIIsKnownByTheHeadersItExposes() {
        #expect(ManagementURL.isCLIProxyAPI(headers: ["Access-Control-Expose-Headers": "X-CPA-TRACE-ID, X-CPA-VERSION, X-CPA-COMMIT"]))
        #expect(ManagementURL.isCLIProxyAPI(headers: ["X-Cpa-Version": "8.0.40"]))
        #expect(!ManagementURL.isCLIProxyAPI(headers: ["Server": "nginx", "Content-Type": "text/html"]))
        #expect(!ManagementURL.isCLIProxyAPI(headers: [:]))
    }
}
