import EbbCore
import SwiftUI

/// The menu bar item: the Tideline mark plus the pool in the style chosen in Settings,
/// by default `5h 88%`. Drawn as one image; see `MenuBarImage`.
struct MenuBarLabel: View {
    let store: PoolStore
    let settings: MenuBarSettings
    /// The pool on show; `nil` while no provider has a login.
    let provider: String?
    /// SwiftUI may build the label while the item is out of the menu bar; the clock below runs only while it shows.
    let isShowing: Bool

    @State private var now = Date.now

    var body: some View {
        let pool = LaunchOptions.demo == .low ? DemoData.lowMenuBarPool(now: now) : store.menuBarPool(for: provider, now: now)
        let item = MenuBarItem(style: settings.style, limit: settings.limit, pool: pool, now: now)
        Image(nsImage: MenuBarImage.cached(item))
            .accessibilityLabel(item.accessibilityLabel)
            // Refill times count down and readings go stale even when nothing new arrives.
            // Not a TimelineView: a menu bar label redraws at once when asked, so it would spin.
            .task(id: isShowing) {
                guard isShowing else { return }
                now = .now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    Budget.wake("menu bar clock")
                    now = .now
                }
            }
            // Increase Contrast changes the item's greys; the system announces the switch, and the item redraws.
            .task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
                    now = .now
                }
            }
    }
}

extension PoolStore {
    /// One provider's pool as the menu bar draws it, or `nil` without a reading.
    func menuBarPool(for provider: String?, now: Date) -> MenuBarPool? {
        guard let provider, let summary = state.summaries[provider] else { return nil }
        let accounts = state.details
            .filter { $0.provider == provider && !$0.isHealthOnly && $0.status != .disabledByUser }
            .map(\.canTakeWork)
        return MenuBarPool(summary: summary, shortWindow: ProviderDisplay.shortWindow(provider), accounts: accounts, lastReadAt: lastReadAt(for: provider), now: now)
    }

    /// A proxy that stopped answering dims the item, even while Claude still reads directly.
    func lastReadAt(for provider: String) -> Date? {
        isProxyUnreachable ? nil : [proxyReadAt, state.usageAPIReadAt[provider]].compactMap { $0 }.max()
    }
}

extension AccountDetail {
    /// Counted in the pool with room left in both windows: a filled dot in the Ring.
    var canTakeWork: Bool {
        guard status == .active || status == .stale, let sessionFree, sessionFree.rounded() > 0 else { return false }
        return 100 - (weeklyFree ?? 100) < Pool.weeklySpentAt
    }
}
