import AppKit
import EbbCore
import SwiftUI

/// `--snapshot <dir>`: renders the panel offscreen to PNGs, dark and light, collapsed, expanded
/// and at Increase Contrast, plus its first-run setup steps, the panel before a reading, every
/// menu bar style and every Settings tab, then quits. The windows it draws in are never put on screen.
@MainActor
enum Snapshot {
    static func write(store: PoolStore, connection: ProxyConnection, to directory: URL, prefix: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let appearance = scheme == .dark ? "dark" : "light"
            for isExpanded in [false, true] {
                let panel = PoolPanel(store: store, connection: connection, showsAccounts: isExpanded)
                let name = "\(prefix)-\(appearance)-\(isExpanded ? "expanded" : "collapsed").png"
                if let data = png(of: panel, scheme: scheme) {
                    try? data.write(to: directory.appending(path: name))
                }
            }
            for (window, card) in hoverCards(store: store) {
                if let data = png(of: card, scheme: scheme) {
                    try? data.write(to: directory.appending(path: "\(prefix)-\(appearance)-hover-\(window).png"))
                }
            }
            // Increase Contrast, collapsed: the tracks, the faint text and the hatch step up a level.
            let panel = PoolPanel(store: store, connection: connection, showsAccounts: false)
                .environment(\._colorSchemeContrast, .increased)
            if let data = png(of: panel, scheme: scheme) {
                try? data.write(to: directory.appending(path: "\(prefix)-\(appearance)-contrast.png"))
            }
            if let data = pngOnRed(of: PoolPanel(store: store, connection: connection, showsAccounts: false), scheme: scheme) {
                try? data.write(to: directory.appending(path: "\(prefix)-\(appearance)-red.png"))
            }
        }
    }

    /// The collapsed panel on the menu material over a saturated red, the wallpaper that made the
    /// meters' segments blur together. The material tints the vibrant colours here as it does on
    /// screen, but the window server's additive blending doesn't reach an offscreen window, so
    /// faint vibrant fills come out dimmer than they would over a bright desktop.
    private static func pngOnRed(of panel: some View, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: panel.environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        let material = NSVisualEffectView(frame: root.bounds)
        material.material = .menu
        material.state = .active
        material.blendingMode = .withinWindow
        material.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        root.addSubview(material)
        window.contentView = root
        settle(host)
        let size = host.fittingSize
        window.setContentSize(size)
        material.frame = NSRect(origin: .zero, size: size)
        host.frame = material.bounds
        settle(host)

        let bounds = root.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        root.cacheDisplay(in: bounds, to: rep)
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    /// The hover card of each window that has one, as the panel would show it.
    private static func hoverCards(store: PoolStore, now: Date = .now) -> [(String, GainBreakdown)] {
        let choice = UserDefaults.standard.string(forKey: ProviderDisplay.panelProviderKey) ?? ""
        let provider = store.state.providers.contains(choice) ? choice : store.menuBarProvider(choice: "")
        guard let provider, let summary = store.state.summaries[provider] else { return [] }
        let short = ProviderDisplay.shortWindow(provider)
        let forecast = store.state.forecasts[provider]
        let cards = [
            ("session", GainBreakdown(
                window: .session, short: short, line: GainLine.session(summary.session.resets), forecast: forecast?.session,
                notes: PoolNotes.lines(summary, window: .session, now: now), now: now
            )),
            ("weekly", GainBreakdown(
                window: .weekly, short: short, line: GainLine.weekly(summary.weekly.resets), forecast: forecast?.weekly,
                budget: summary.weeklyBudget, notes: PoolNotes.lines(summary, window: .weekly, now: now), now: now
            )),
        ]
        return cards.filter { $0.1.line != nil || $0.1.forecast != nil }
    }

    /// Draws at 2x on the window background, with every animation finished.
    private static func png(of panel: some View, scheme: ColorScheme) -> Data? {
        let root = panel
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }
        return png(of: root, width: 300, scheme: scheme)
    }

    private static func png(of root: some View, width: CGFloat, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
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

    /// The panel's setup steps in each state a fresh Mac can be in, dark and light.
    static func writeSetup(model: AppModel, to directory: URL) {
        let states: [(String, ProxySetup)] = [
            ("looking", ProxySetup(proxy: .looking, key: .waiting, hasLogins: false)),
            ("not-installed", ProxySetup(proxy: .notInstalled, key: .waiting, hasLogins: false)),
            ("stopped", ProxySetup(proxy: .stopped(.homebrew(prefix: "/opt/homebrew")), key: .waiting, hasLogins: false)),
            ("stopped-other", ProxySetup(proxy: .stopped(.other), key: .waiting, hasLogins: false)),
            ("management-off", ProxySetup(proxy: .running, key: .managementOff, hasLogins: false)),
            ("no-key", ProxySetup(proxy: .running, key: .needed, hasLogins: false)),
            ("checking", ProxySetup(proxy: .running, key: .checking, hasLogins: false)),
            ("key-rejected", ProxySetup(proxy: .running, key: .refused, hasLogins: false)),
            ("stopped-with-logins", ProxySetup(proxy: .stopped(.homebrew(prefix: "/opt/homebrew")), key: .waiting, hasLogins: true)),
            ("no-key-with-logins", ProxySetup(proxy: .running, key: .needed, hasLogins: true)),
        ]
        for scheme in [ColorScheme.dark, .light] {
            for (name, setup) in states {
                let panel = PoolPanel(store: model.store, connection: model.connection, setup: setup)
                if let data = png(of: panel, scheme: scheme) {
                    try? data.write(to: directory.appending(path: "setup-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// The panel before any account could be read, dark and light.
    static func writeNoReading(model: AppModel, to directory: URL) {
        let store = PoolStore(connection: model.connection, summary: nil, details: [], proxyReadAt: nil)
        for scheme in [ColorScheme.dark, .light] {
            let panel = PoolPanel(store: store, connection: model.connection, showsAccounts: false)
            if let data = png(of: panel, scheme: scheme) {
                try? data.write(to: directory.appending(path: "no-reading-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// Every Settings tab, dark and light, at the Settings window's width and capped as the window caps it.
    static func writeSettings(model: AppModel, to directory: URL) {
        let settings = SettingsView(connection: model.connection, visibility: model.visibility, store: model.store, menuBarSettings: model.menuBarSettings)
        for scheme in [ColorScheme.dark, .light] {
            for tab in SettingsTab.allCases {
                let view = settings.pane(tab)
                    .frame(width: 480)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                    .transaction { $0.disablesAnimations = true }
                if let data = png(of: view, width: 480, scheme: scheme) {
                    try? data.write(to: directory.appending(path: "settings-\(tab.rawValue.lowercased())-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// Every menu bar style on light, dark and red-wallpaper bars at 88%, 15% and 5% free, at 2x,
    /// one file each plus a sheet of all of them; the Ring again at 1x, where it drops its dots.
    static func writeMenuBar(to directory: URL) {
        let now = Date.now
        let levels: [(session: Int, weekly: Int, refill: Double)] = [(88, 45, 130), (15, 45, 100), (5, 8, 38)]
        var sheet: [[NSImage]] = []
        for style in MenuBarStyle.allCases {
            var row: [NSImage] = []
            for bar in MenuBarSample.allCases {
                for level in levels {
                    let pool = MenuBarPool(
                        session: WindowReading(window: .session, percent: level.session, refillsAt: now + level.refill * 60),
                        weekly: WindowReading(window: .weekly, percent: level.weekly, refillsAt: now + 3 * 86400),
                        accounts: [true, true, level.session > 15, false],
                        lastReadAt: now
                    )
                    let item = MenuBarItem(style: style, limit: .fiveHour, pool: pool, now: now)
                    let cell = bar.render(item)
                    row.append(cell)
                    let name = "menubar-\(style.rawValue)-\(bar.rawValue)-\(level.session).png"
                    if let data = bitmap(cell, scale: 2) { try? data.write(to: directory.appending(path: name)) }
                    if style == .ring, let data = bitmap(cell, scale: 1) {
                        try? data.write(to: directory.appending(path: "menubar-ring-\(bar.rawValue)-\(level.session)@1x.png"))
                    }
                }
            }
            sheet.append(row)
        }
        if let data = bitmap(contactSheet(sheet), scale: 2) {
            try? data.write(to: directory.appending(path: "menubar-sheet.png"))
        }
    }

    /// The menu bar strips in a grid: a row per style, columns light, dark and wallpaper at each level.
    private static func contactSheet(_ rows: [[NSImage]]) -> NSImage {
        let cell = NSSize(width: 130, height: MenuBarImage.height)
        let gap: CGFloat = 6
        let labelWidth: CGFloat = 86
        let columns = rows.first?.count ?? 0
        let size = NSSize(width: labelWidth + CGFloat(columns) * (cell.width + gap), height: CGFloat(rows.count) * (cell.height + gap) + gap)
        return NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, row) in rows.enumerated() {
                let y = gap + CGFloat(index) * (cell.height + gap)
                (MenuBarStyle.allCases[index].title as NSString).draw(
                    at: NSPoint(x: 6, y: y + 4),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black]
                )
                for (column, image) in row.enumerated() {
                    image.draw(in: NSRect(x: labelWidth + CGFloat(column) * (cell.width + gap), y: y, width: cell.width, height: cell.height))
                }
            }
            return true
        }
    }

    private static func bitmap(_ image: NSImage, scale: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
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
        func weight(_ plan: String) -> PlanWeight {
            PlanWeights.defaultWeight(provider: ClaudeProvider().proxyName, plan: plan) ?? PlanWeight(1)
        }
        let accounts: [(email: String, weight: PlanWeight, limits: [UsageLimit], share: Double)] = [
            ("work@example.com", weight("max_20x"), limits(session: 64, sessionResetIn: 132, weekly: 71, weeklyResetIn: 2 * 24 * 60 + 300), 18),
            ("research@example.com", weight("max_5x"), limits(session: 12, sessionResetIn: 41, weekly: nil, weeklyResetIn: 0), 34),
            ("side@example.com", weight("max_5x"), limits(session: 30, sessionResetIn: 250, weekly: nil, weeklyResetIn: 0), 27),
            ("lab@example.com", weight("max_5x"), limits(session: 48, sessionResetIn: 95, weekly: nil, weeklyResetIn: 0), 21),
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

/// The bars the snapshot draws the menu bar item on, matching the design record's sheet.
private enum MenuBarSample: String, CaseIterable {
    case light, dark, wallpaper

    /// The item centred on a 130 × 22 pt strip, coloured the way the menu bar colours it.
    @MainActor
    func render(_ item: MenuBarItem) -> NSImage {
        let isDark = self != .light
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        let image = MenuBarImage.make(item, appearance: appearance)
        let size = NSSize(width: 130, height: MenuBarImage.height)
        return NSImage(size: size, flipped: false) { rect in
            background.draw(in: NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7), angle: self == .wallpaper ? -60 : -10)
            let frame = NSRect(x: ((size.width - image.size.width) / 2).rounded(), y: 0, width: image.size.width, height: image.size.height)
            if image.isTemplate {
                // What the menu bar does with a template: its alpha, in the bar's text colour.
                let tinted = NSImage(size: image.size, flipped: false) { bounds in
                    image.draw(in: bounds)
                    (isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)).setFill()
                    bounds.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: frame)
            } else {
                appearance.performAsCurrentDrawingAppearance { image.draw(in: frame) }
            }
            return true
        }
    }

    private var background: NSGradient {
        switch self {
        case .light: NSGradient(starting: NSColor(srgbRed: 0.914, green: 0.933, blue: 0.957, alpha: 1), ending: NSColor(srgbRed: 0.843, green: 0.878, blue: 0.918, alpha: 1))!
        case .dark: NSGradient(starting: NSColor(srgbRed: 0.114, green: 0.133, blue: 0.161, alpha: 1), ending: NSColor(srgbRed: 0.078, green: 0.094, blue: 0.114, alpha: 1))!
        case .wallpaper: NSGradient(colors: [
                NSColor(srgbRed: 0.765, green: 0.208, blue: 0.169, alpha: 1),
                NSColor(srgbRed: 0.478, green: 0.078, blue: 0.063, alpha: 1),
                NSColor(srgbRed: 0.227, green: 0.031, blue: 0.024, alpha: 1),
            ])!
        }
    }
}
