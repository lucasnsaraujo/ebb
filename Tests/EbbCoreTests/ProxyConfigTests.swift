import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct ProxyConfigTests {
    @Test func currentLayoutIsRead() {
        let yaml = """
        config-version: 8
        server:
          host: ""
          port: 8318 # moved off the default
          tls:
            enable: true
        management:
          secret-key: "$2a$10$hash#notacomment"
        access:
          api-keys:
            - "sk-example"
        oauth:
          auth-dir: "~/logins"
        """
        let config = ProxyConfig.parse(yaml)
        #expect(config == ProxyConfig(host: "", port: 8318, usesTLS: true, authDirectory: "~/logins"))
        #expect(config.baseURL.absoluteString == "https://127.0.0.1:8318")
    }

    @Test func legacyTopLevelKeysAreRead() {
        let yaml = """
        host: 192.168.1.5
        port: 9000
        auth-dir: /srv/proxy/auths
        tls:
          enable: false
        """
        let config = ProxyConfig.parse(yaml)
        #expect(config == ProxyConfig(host: "192.168.1.5", port: 9000, usesTLS: false, authDirectory: "/srv/proxy/auths"))
        #expect(config.baseURL.absoluteString == "http://192.168.1.5:9000")
    }

    @Test func missingKeysFallBackToTheProxyDefaults() {
        #expect(ProxyConfig.parse("# empty\n") == .defaults)
        #expect(ProxyConfig.defaults.baseURL.absoluteString == "http://127.0.0.1:8317")
    }

    @Test func authDirectoryExpandsTheHomeFolder() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(ProxyConfig.defaults.authDirectoryURL(home: home).path == "/Users/example/.cli-proxy-api")
        let absolute = ProxyConfig(host: "", port: 1, usesTLS: false, authDirectory: "/srv/auths")
        #expect(absolute.authDirectoryURL(home: home).path == "/srv/auths")
    }

    @Test func overrideAndEnvironmentComeBeforeTheUsualLocations() {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = ProxyConfig.candidatePaths(override: "~/custom.yaml", environment: ["CLIPROXY_CONFIG": "/etc/proxy.yaml"], home: home)
        #expect(paths.map(\.path) == [
            "/Users/example/custom.yaml",
            "/etc/proxy.yaml",
            "/opt/homebrew/etc/cliproxyapi.conf",
            "/usr/local/etc/cliproxyapi.conf",
            "/Users/example/.cli-proxy-api/config.yaml",
        ])
        #expect(ProxyConfig.candidatePaths(override: nil, environment: [:], home: home).count == 3)
    }

    /// CLIProxyAPI keeps its management API off until the config has a secret-key, plain or hashed.
    @Test func managementIsOnOnlyWithASecretKey() {
        #expect(!ProxyConfig.hasManagementKey("management:\n  allow-remote: false\n  secret-key: \"\"\n"))
        #expect(!ProxyConfig.hasManagementKey("server:\n  port: 8317\n"))
        #expect(ProxyConfig.hasManagementKey("management:\n  secret-key: \"$2a$10$hash\"\n"))
        #expect(ProxyConfig.hasManagementKey("remote-management:\n  secret-key: plain-example\n"))
    }

    /// The current spelling wins when both are present, even when it's empty.
    @Test func theCurrentSecretKeyOutranksTheLegacyOne() {
        #expect(!ProxyConfig.hasManagementKey("management:\n  secret-key: \"\"\nremote-management:\n  secret-key: old-example\n"))
    }
}
