import AppKit
import EbbCore
import SwiftUI

/// How a provider is named and marked in the UI. Claude keeps its own mark; the rest get a
/// lettered SF Symbol, since their logos aren't Ebb's to ship.
enum ProviderDisplay {
    static let menuBarProviderKey = "menuBarProvider"
    static let panelProviderKey = "panelProvider"

    private static let healthOnlyTitles = [
        "xai": "xAI", "gemini": "Gemini API", "gemini-interactions": "Gemini API", "vertex": "Vertex AI",
        "aistudio": "AI Studio", "gemini-cli": "Gemini CLI",
    ]

    static func title(_ provider: String) -> String {
        Providers.named(provider)?.title ?? healthOnlyTitles[provider] ?? provider
    }

    static func shortWindow(_ provider: String?) -> ShortWindow {
        provider.flatMap(Providers.named)?.shortWindow ?? .fiveHours
    }

    static func symbol(_ provider: String) -> String {
        let letter = title(provider).lowercased().first.map(String.init) ?? "questionmark"
        return letter.first?.isLetter == true ? "\(letter).square.fill" : "square.fill"
    }

    static func isClaude(_ provider: String?) -> Bool {
        provider == nil || provider == ClaudeProvider().proxyName
    }
}

extension ShortWindow {
    var title: String {
        switch self {
        case .fiveHours: "5-hour"
        case .day: "Daily"
        }
    }

    /// The account columns' header and the menu bar's prefix.
    var abbreviation: String {
        switch self {
        case .fiveHours: "5h"
        case .day: "1d"
        }
    }
}

/// The panel header's mark for the pool on show.
struct ProviderMark: View {
    let provider: String?

    var body: some View {
        if ProviderDisplay.isClaude(provider) {
            ClaudeMark()
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 14, height: 14)
        } else if let provider {
            Image(systemName: ProviderDisplay.symbol(provider))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}
