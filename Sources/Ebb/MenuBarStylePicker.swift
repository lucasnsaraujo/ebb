import EbbCore
import SwiftUI

/// Settings' style choice: a tile per style, each a live render of the real menu bar image
/// on a strip of menu bar over a slice of wallpaper in the current appearance.
struct MenuBarStylePicker: View {
    @Binding var selection: MenuBarStyle
    let limit: MenuBarLimit
    /// The pool the menu bar shows; sample numbers stand in until there's a reading.
    let pool: MenuBarPool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                ForEach(MenuBarStyle.allCases) { style in
                    StyleTile(style: style, limit: limit, pool: pool ?? Self.sample, isSelected: selection == style) {
                        selection = style
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style")
    }

    private static var sample: MenuBarPool {
        let now = Date.now
        return MenuBarPool(
            session: WindowReading(window: .session, percent: 88, refillsAt: now + 130 * 60),
            weekly: WindowReading(window: .weekly, percent: 45, refillsAt: now + 3 * 86400),
            accounts: [true, true, true, false],
            lastReadAt: now
        )
    }
}

private struct StyleTile: View {
    let style: MenuBarStyle
    let limit: MenuBarLimit
    let pool: MenuBarPool
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let corner: CGFloat = 9
    private static let lightWallpaper = [Color(red: 0.914, green: 0.933, blue: 0.957), Color(red: 0.843, green: 0.878, blue: 0.918)]
    private static let darkWallpaper = [Color(red: 0.114, green: 0.133, blue: 0.161), Color(red: 0.078, green: 0.094, blue: 0.114)]
    private static let ring: CGFloat = 2.5

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                thumbnail
                Text(style.title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isDark: Bool { colorScheme == .dark }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return shape
            .fill(LinearGradient(colors: isDark ? Self.darkWallpaper : Self.lightWallpaper, startPoint: .leading, endPoint: .trailing))
            .frame(height: 46)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    menuBarImage(fitting: proxy.size.width - 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
                .frame(height: MenuBarImage.height)
                .background(isDark ? Color.black.opacity(0.2) : Color.white.opacity(0.25))
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.15), lineWidth: 0.5) }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.corner + Self.ring, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: Self.ring)
                        .padding(-Self.ring)
                }
            }
    }

    /// The image the status item would get, coloured the way the menu bar colours it.
    /// At real size, unless it's wider than the tile: Both and Refill time shrink to fit.
    private func menuBarImage(fitting width: CGFloat) -> some View {
        let item = MenuBarItem(style: style, limit: limit, pool: pool, now: .now)
        let image = MenuBarImage.make(item, appearance: NSAppearance(named: isDark ? .darkAqua : .aqua))
        let scale = min(1, max(width, 1) / image.size.width)
        return Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .resizable()
            .foregroundStyle(isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.86))
            .frame(width: image.size.width * scale, height: image.size.height * scale)
    }
}
