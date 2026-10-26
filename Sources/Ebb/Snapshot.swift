import AppKit
import EbbCore
import SwiftUI

/// `--snapshot <dir>`: renders the panel offscreen to PNGs, dark and light, collapsed and
/// expanded, then quits. The window it draws in is never put on screen.
@MainActor
enum Snapshot {
    static func write(store: PoolStore, connection: ProxyConnection, visibility: Visibility, to directory: URL, prefix: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            for isExpanded in [false, true] {
                let panel = PoolPanel(store: store, visibility: visibility, connection: connection, showsAccounts: isExpanded)
                let name = "\(prefix)-\(scheme == .dark ? "dark" : "light")-\(isExpanded ? "expanded" : "collapsed").png"
                if let data = png(of: panel, scheme: scheme) {
                    try? data.write(to: directory.appending(path: name))
                }
            }
        }
    }

    /// Draws at 2x on the window background, with every animation finished.
    private static func png(of panel: PoolPanel, scheme: ColorScheme) -> Data? {
        let root = panel
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        settle(host)
        window.setContentSize(host.fittingSize)
        settle(host)

        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    /// Lets SwiftUI run `onAppear` and lay out before drawing.
    private static func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.15)
        }
    }

    /// Four Claude logins with fixed numbers, dated relative to now so every render reads alike.
    static func claudeOnly(connection: ProxyConnection, now: Date = .now) -> PoolStore {
        func limits(session: Double, sessionResetIn: Double, weekly: Double?, weeklyResetIn: Double) -> [UsageLimit] {
            [UsageLimit(kind: .session, usedPercent: session, resetsAt: now + sessionResetIn * 60)]
                + (weekly.map { [UsageLimit(kind: .weeklyAll, usedPercent: $0, resetsAt: now + weeklyResetIn * 60)] } ?? [])
        }
        let accounts: [(email: String, weight: Double, limits: [UsageLimit], share: Double)] = [
            ("work@example.com", 20, limits(session: 64, sessionResetIn: 132, weekly: 71, weeklyResetIn: 2 * 24 * 60 + 300), 18),
            ("research@example.com", 5, limits(session: 12, sessionResetIn: 41, weekly: nil, weeklyResetIn: 0), 34),
            ("side@example.com", 5, limits(session: 30, sessionResetIn: 250, weekly: nil, weeklyResetIn: 0), 27),
            ("lab@example.com", 5, limits(session: 48, sessionResetIn: 95, weekly: nil, weeklyResetIn: 0), 21),
        ]
        let summary = Pool.summarize(accounts.map { AccountUsage(weight: $0.weight, limits: $0.limits) }, at: now)
        let details = accounts.map { account in
            AccountDetail(
                email: account.email,
                plan: .paid(weight: account.weight),
                status: .active,
                sessionFree: 100 - (account.limits.first { $0.kind == .session }?.usedPercent ?? 0),
                weeklyFree: account.limits.first { $0.kind == .weeklyAll }.map { 100 - $0.usedPercent },
                share: account.share,
                readAt: now - 150
            )
        }.sorted { $0.label < $1.label }
        return PoolStore(connection: connection, summary: summary, details: details, proxyReadAt: now - 150)
    }
}
