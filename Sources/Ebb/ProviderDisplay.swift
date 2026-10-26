import AppKit
import EbbCore
import SwiftUI

/// How a provider is named in the UI. Its mark is `ProviderLogo`.
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
}

/// A provider's logo from Simple Icons, or a two-letter tile where there's none, drawn in one
/// colour at the size of an SF Symbol in the row's text.
struct ProviderLogo: View {
    let provider: String

    private static let size: CGFloat = 13
    private static let letterFont = Font(NSFont.compactRounded(size: 7, weight: 600))

    var body: some View {
        Group {
            switch ProviderMark.forProvider(named: provider) ?? .letters(ProviderMark.letters(forName: ProviderDisplay.title(provider))) {
            case let .logo(icon):
                // Logos run to the edge of their box; a point less matches a symbol's optical size.
                SimpleIconShape(icon: icon)
                    .padding(0.5)
            case let .letters(code):
                // The design record's tile (radius 4.25 on 16 pt), with letters a little larger
                // than its 7.8 pt so two of them stay legible at row size.
                RoundedRectangle(cornerRadius: 4.25 * Self.size / 16, style: .continuous)
                    .inset(by: 0.5)
                    .overlay {
                        Text(code)
                            .font(Self.letterFont)
                            .tracking(-0.15)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
        .frame(width: Self.size, height: Self.size)
        .help(ProviderDisplay.title(provider))
        .accessibilityLabel(ProviderDisplay.title(provider))
    }
}

/// A Simple Icons path, fitted into the frame and centred.
private struct SimpleIconShape: Shape {
    /// Parsed once, by slug.
    private static let paths = Dictionary(uniqueKeysWithValues: SimpleIcon.all.map { icon in
        (icon.slug, SVGPath.cgPath(icon.pathData).map { Path($0) } ?? Path())
    })

    let path: Path

    init(icon: SimpleIcon) {
        path = Self.paths[icon.slug] ?? Path()
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / SimpleIcon.viewBox
        let bounds = path.boundingRect
        return path.applying(
            CGAffineTransform(translationX: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
                .scaledBy(x: scale, y: scale)
        )
    }
}
