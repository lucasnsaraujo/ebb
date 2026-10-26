import EbbCore
import Foundation

/// Ebb's own files. The mode file lives in `~/.config/ebb` so scripts can flip it.
enum EbbPaths {
    static let bundleIdentifier = "io.github.lucasnsaraujo.ebb"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Ebb")
    static let managementKeyFile = applicationSupport.appending(path: "management-key")
    static let configDirectory = home.appending(path: ".config/ebb")
    static let modeFile = configDirectory.appending(path: "mode")
    static let retiredAccounts = RetiredAccounts(file: configDirectory.appending(path: "retired.json"))
    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: bundleIdentifier)

    static func usageCache(for email: String) -> URL {
        cacheDirectory.appending(path: "\(email).usage.json")
    }

    static func planCache(for email: String) -> URL {
        cacheDirectory.appending(path: "\(email).plan.json")
    }

    /// Contents and modification date of a cache file.
    static func readCache(_ url: URL) -> (data: Data, modified: Date)? {
        guard let data = try? Data(contentsOf: url),
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        return (data, modified)
    }

    /// `date` becomes the file's modification date: when the reading was taken.
    static func writeCache(_ data: Data, to url: URL, date: Date = .now) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// One Claude login from CLIProxyAPI's auth folder, read directly so Claude keeps working
/// without a management key. The proxy refreshes `access_token` in place, so read the file
/// again before each request. Other providers are never read from disk: Ebb reaches them
/// through the proxy's `api-call`, which fills in the token.
struct ProxyAccount {
    let file: URL
    let provider = ClaudeProvider()
    let email: String
    let accessToken: String
    /// As written in the file; the management API's view wins when it's reachable.
    let isDisabledInFile: Bool

    /// The management API's key for this login.
    var name: String { file.lastPathComponent }

    private struct Fields: Decodable {
        let type: String?
        let email: String?
        let accessToken: String?
        let disabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case type, email, disabled
            case accessToken = "access_token"
        }
    }

    /// Every Claude login, including disabled ones.
    static func loadAll(in directory: URL) -> [ProxyAccount] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { file -> ProxyAccount? in
                guard let data = try? Data(contentsOf: file),
                      let fields = try? JSONDecoder().decode(Fields.self, from: data),
                      fields.type == ClaudeProvider().proxyName,
                      let email = fields.email, !email.isEmpty,
                      let accessToken = fields.accessToken, !accessToken.isEmpty
                else { return nil }
                return ProxyAccount(file: file, email: email, accessToken: accessToken, isDisabledInFile: fields.disabled ?? false)
            }
            .sorted { $0.name < $1.name }
    }
}
