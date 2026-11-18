import SwiftUI

/// The CLIProxyAPI instances Ebb can show, one at a time, each with its own address, key and
/// saved state. Claude is the proxy Ebb always had: it keeps the setting names and files from
/// before there were two, and alone may follow this Mac's config file and logins folder.
/// Antigravity is reached only by an address set in Settings.
enum ProxyPool: String, CaseIterable, Identifiable {
    case claude, antigravity

    /// The pool on show in the panel and the menu bar.
    static let selectionKey = "proxyPool"

    var id: Self { self }

    /// Product names, the same in every language.
    var title: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }

    var followsLocalConfig: Bool {
        self == .claude
    }

    /// This pool's copy of a saved setting.
    func key(_ name: String) -> String {
        self == .claude ? name : "\(rawValue).\(name)"
    }

    /// This pool's copy of one of Ebb's files, beside the original.
    func file(_ url: URL) -> URL {
        self == .claude ? url : url.deletingLastPathComponent().appending(path: "\(rawValue)-\(url.lastPathComponent)")
    }
}

/// Claude | Antigravity, at the top of the panel and of Settings → Connection.
struct ProxyPoolPicker: View {
    let selection: Binding<ProxyPool>

    var body: some View {
        Picker("Proxy", selection: selection) {
            ForEach(ProxyPool.allCases) { pool in
                Text(verbatim: pool.title).tag(pool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Proxy")
    }
}

/// One pool's proxy and the numbers read from it.
struct PoolSource {
    let connection: ProxyConnection
    let store: PoolStore
}
