import AppKit
import CoreImage
import EbbCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `--record <dir>`: draws the launch media offscreen from the demo data, then quits:
/// `hero-dark.png` and `hero-light.png`, the demo video as 60 fps dark frames in `frames/`, and
/// the same scene with the camera held still at 20 fps in `gif-frames/`, for ffmpeg. The panel,
/// its hover card and the menu bar item are Ebb's own views and images; the desktop, the other
/// menu bar glyphs and the pointer are drawn here. Nothing goes on screen.
@MainActor
enum Recorder {
    static let fps = 60.0
    static let videoSize = CGSize(width: 1440, height: 900)
    static let gifFPS = 20.0
    static let gifSize = CGSize(width: 800, height: 625)
    /// Where the GIF's still camera looks: a GIF pays for every pixel that changes, so nothing pans.
    static let gifRect = CGRect(x: 360, y: 0, width: 640, height: 500)

    static func write(model: AppModel, to directory: URL) {
        // The argument domain lives only as long as this run, so the app's own choice stays put.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(arguments.merging([ProviderDisplay.panelProviderKey: ClaudeProvider().proxyName]) { $1 }, forName: UserDefaults.argumentDomain)
        let frames = directory.appending(path: "frames")
        let gifFrames = directory.appending(path: "gif-frames")
        for folder in [frames, gifFrames] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            removeFrames(in: folder)
        }
        let light = Desk(model: model, scheme: .light)
        save(light.render(Script.hero, size: Desk.heroSize, visible: Desk.heroRect), to: directory.appending(path: "hero-light.png"))
        let dark = Desk(model: model, scheme: .dark)
        save(dark.render(Script.hero, size: Desk.heroSize, visible: Desk.heroRect), to: directory.appending(path: "hero-dark.png"))
        let script = Script(desk: dark)
        // Drawing text leaves autoreleased objects behind; draining per frame keeps memory flat.
        for index in 0..<Int((Script.duration * fps).rounded()) {
            autoreleasepool {
                let shot = script.shot(at: Double(index) / fps)
                let image = dark.render(shot, size: videoSize, visible: dark.visibleRect(shot.camera, size: videoSize))
                save(image, to: frames.appending(path: String(format: "%04d.png", index)))
            }
        }
        for index in 0..<Int((Script.duration * gifFPS).rounded()) {
            autoreleasepool {
                var shot = script.shot(at: Double(index) / gifFPS)
                shot.depth = 0
                save(dark.render(shot, size: gifSize, visible: gifRect), to: gifFrames.appending(path: String(format: "%04d.png", index)))
            }
        }
    }

    /// Clears an earlier run's `0000.png`… so a shorter script leaves no stale frames; nothing else.
    private static func removeFrames(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.count == 8 && name.hasSuffix(".png") && name.prefix(4).allSatisfy(\.isNumber) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    private static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Script

/// One moment of the scene. Times are seconds since the event, `nil` before it.
private struct Shot {
    var camera = Camera(zoom: 1.8, focus: .zero)
    var pointer: CGPoint?
    /// 0–1, the button held down.
    var press = 0.0
    var opened: Double?
    var expanded: Double?
    var rowHover = 0.0
    var labelHover = 0.0
    var cardOpened: Double?
    var cardClosed: Double?
    /// The pool's 5-hour reading, 43%, 42% or 41% as 0, 1, 2, and the time since it last changed.
    var reading = 0
    var ticked: Double?
    /// How far the desktop behind is blurred, 0–1, while the camera sits close.
    var depth = 0.0
}

private struct Camera {
    var zoom: CGFloat
    var focus: CGPoint
}

/// Opens the panel, expands the accounts, hovers the 5-hour pace line, then watches the menu bar
/// item and the panel tick down from 43% to 41% up close, and pulls back to a clean frame.
@MainActor
private struct Script {
    static let duration = 16.4

    /// The README hero: the panel open with its accounts, no pointer.
    static let hero = Shot(opened: 10, expanded: 10)

    private var moves: [Move] = []
    private var cameras: [(start: Double, length: Double, to: Camera)] = []

    private struct Move {
        let start: Double
        let length: Double
        let from: CGPoint
        let to: CGPoint
        /// Sideways bow of the path, in points.
        let arc: CGFloat
    }

    init(desk: Desk) {
        let item = CGPoint(x: desk.item.midX - 6, y: 13)
        let row = desk.inPanel(CGPoint(x: desk.rowRect.minX + 86, y: desk.rowRect.midY + 1))
        let label = desk.inPanel(CGPoint(x: desk.labelRect.minX + desk.labelRect.width * 0.58, y: desk.labelRect.midY + 1))
        moves = [
            Move(start: 0.30, length: 1.15, from: CGPoint(x: 500, y: 380), to: item, arc: 40),
            Move(start: 2.55, length: 0.95, from: item, to: row, arc: -24),
            Move(start: 5.25, length: 0.85, from: row, to: label, arc: 18),
            Move(start: 9.20, length: 1.10, from: label, to: CGPoint(x: 330, y: 640), arc: -36),
        ]
        let wide = Camera(zoom: 1.8, focus: CGPoint(x: 600, y: 250))
        let panel = Camera(zoom: 2.1, focus: CGPoint(x: desk.panelOrigin.x + 120, y: 0))
        let card = Camera(zoom: Recorder.videoSize.height / (desk.cardBottom + 26), focus: CGPoint(x: desk.panelOrigin.x + 90, y: 0))
        let close = Camera(zoom: 2.7, focus: CGPoint(x: desk.item.midX + 90, y: 0))
        cameras = [
            (0, 0, Camera(zoom: 1.74, focus: wide.focus)),
            (0, 1.5, wide),
            (1.75, 1.45, panel),
            (3.45, 1.0, wide),
            (5.4, 1.6, card),
            (9.45, 1.4, close),
            (13.1, 1.6, wide),
            (14.7, 1.7, Camera(zoom: 1.82, focus: wide.focus)),
        ]
    }

    func shot(at time: Double) -> Shot {
        let since = { (event: Double) in time >= event ? time - event : nil }
        var shot = Shot()
        shot.camera = camera(at: time)
        shot.pointer = pointer(at: time)
        shot.press = [1.50, 3.86].map { press(time - $0) }.max() ?? 0
        shot.opened = since(1.52)
        shot.expanded = since(3.95)
        shot.rowHover = fade(time, on: 3.42, off: 5.32, length: 0.12)
        shot.labelHover = fade(time, on: 6.0, off: 9.25, length: 0.01)
        shot.cardOpened = since(6.3)
        shot.cardClosed = since(9.25)
        let ticks = [11.2, 12.3].filter { time >= $0 }
        shot.reading = ticks.count
        shot.ticked = ticks.last.map { time - $0 }
        shot.depth = fade(time, on: 9.6, off: 13.1, length: 1.3)
        return shot
    }

    private func pointer(at time: Double) -> CGPoint? {
        var point = moves[0].from
        for move in moves where time >= move.start {
            let eased = CGFloat(Ease.minimumJerk(min((time - move.start) / move.length, 1)))
            let length = max(hypot(move.to.x - move.from.x, move.to.y - move.from.y), 1)
            let bow = move.arc * sin(.pi * eased)
            point = CGPoint(
                x: move.from.x + (move.to.x - move.from.x) * eased - (move.to.y - move.from.y) / length * bow,
                y: move.from.y + (move.to.y - move.from.y) * eased + (move.to.x - move.from.x) / length * bow
            )
        }
        return point
    }

    /// Eases zoom geometrically, so pushing in and pulling out feel the same speed.
    private func camera(at time: Double) -> Camera {
        var current = cameras[0].to
        for (start, length, target) in cameras where time >= start {
            let progress = length == 0 ? 1 : CGFloat(Ease.minimumJerk(min((time - start) / length, 1)))
            current = Camera(
                zoom: current.zoom * pow(target.zoom / current.zoom, progress),
                focus: CGPoint(x: current.focus.x + (target.focus.x - current.focus.x) * progress, y: current.focus.y + (target.focus.y - current.focus.y) * progress)
            )
        }
        return current
    }

    /// Quick to press, springs back on release.
    private func press(_ into: Double) -> Double {
        guard into >= 0, into < 0.4 else { return 0 }
        return into < 0.09 ? Ease.out(into / 0.09) : 1 - Ease.spring(into - 0.09, response: 0.22, damping: 0.6)
    }

    private func fade(_ time: Double, on: Double, off: Double, length: Double) -> Double {
        min(step(time, at: on, length: length), 1 - step(time, at: off, length: length))
    }

    private func step(_ time: Double, at start: Double, length: Double) -> Double {
        Ease.inOut(min(max((time - start) / length, 0), 1))
    }
}

private enum Ease {
    /// The bell-shaped speed of a hand reaching for a target.
    static func minimumJerk(_ t: Double) -> Double {
        t * t * t * (10 - 15 * t + 6 * t * t)
    }

    static func out(_ t: Double) -> Double {
        1 - pow(1 - min(max(t, 0), 1), 3)
    }

    static func inOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func spring(_ time: Double, response: Double, damping: Double) -> Double {
        time <= 0 ? 0 : Spring(response: response, dampingRatio: damping).value(target: 1.0, time: time)
    }

    /// `Motion.reveal`, the panel's own spring for the accounts; an `Animation` can't be sampled, so its numbers are repeated here.
    static func reveal(_ time: Double) -> Double {
        spring(time, response: 0.35, damping: 0.85)
    }

    /// SwiftUI's `.smooth`, which the panel's numbers and meters move on.
    static func smooth(_ time: Double) -> Double {
        time <= 0 ? 0 : Spring.smooth.value(target: 1.0, time: time)
    }
}

// MARK: - Desk

/// One appearance of the scene: the desktop, the menu bar and Ebb's panel, drawn in points
/// on a 1000 × 640 pt screen whose right edge holds the menu bar's status items.
@MainActor
private final class Desk {
    static let screen = CGSize(width: 1000, height: 640)
    static let heroSize = CGSize(width: 1440, height: 1000)
    static let heroRect = CGRect(x: 280, y: 0, width: 720, height: 500)
    private static let barHeight: CGFloat = 24
    private static let layerScale: CGFloat = 3

    let isDark: Bool
    private(set) var item = CGRect.zero
    private(set) var panelOrigin = CGPoint.zero
    /// In panel points: the Accounts row's hover background and the 5-hour pace line.
    private(set) var rowRect = CGRect.zero
    private(set) var labelRect = CGRect.zero

    private let wallpaper: CGImage
    private let blurredWallpaper: CGImage
    private let collapsed: CGImage
    /// The open panel at each reading.
    private let expanded: [CGImage]
    private let card: CGImage
    private let readings: [NSImage]
    private var glyphs: [(image: NSImage, rect: CGRect)] = []
    private var clock: (text: NSAttributedString, origin: CGPoint)
    private var cardBackdrop: (image: CGImage, rect: CGRect)?

    // Slices of the panel, in its points.
    private var topCut: CGFloat = 0
    private var dividerTop: CGFloat = 0
    private var chevron = CGRect.zero
    private var accountBands: [CGRect] = []
    private var accountsBottom: CGFloat = 0
    /// The 5-hour number's last digit, the only one that changes from 43 to 41, sharp and blurred.
    private var digit = CGRect.zero
    private var digits: [(sharp: CGImage, blurred: CGImage)] = []

    /// The menu bar clock's format: "Tue Oct 27  9:12 AM".
    private static func clockText(_ date: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEMMMd", options: 0, locale: .current)?.replacingOccurrences(of: ",", with: "")
        return day.string(from: date) + "  " + date.formatted(date: .omitted, time: .shortened)
    }

    init(model: AppModel, scheme: ColorScheme) {
        isDark = scheme == .dark
        let claude = ClaudeProvider().proxyName
        let now = Date.now
        let store = model.store
        let stores = [store] + [(34.0, 42.0), (32.0, 41.0)].map { Self.later(store, connection: model.connection, sessionFree: $0.0, pool: $0.1) }
        func panel(_ store: PoolStore, expanded: Bool) -> CGImage {
            Self.render(PoolPanel(store: store, connection: model.connection, showsAccounts: expanded), width: 300, scheme: scheme)
        }
        collapsed = panel(store, expanded: false)
        expanded = stores.map { panel($0, expanded: true) }
        let summary = store.state.summaries[claude]
        card = Self.render(GainBreakdown(
            window: .session,
            short: ProviderDisplay.shortWindow(claude),
            line: summary.flatMap { GainLine.session($0.session.resets.filter { $0.date > now }) },
            forecast: store.state.forecasts[claude]?.session,
            notes: summary.map { PoolNotes.lines($0, window: .session, now: now) } ?? [],
            now: now
        ), width: 300, scheme: scheme)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        readings = stores.map { store in
            MenuBarImage.make(MenuBarItem(style: .standard, limit: .fiveHour, pool: store.menuBarPool(for: claude, now: now), now: now), appearance: appearance)
        }
        wallpaper = Self.wallpaper(isDark: isDark)
        blurredWallpaper = Self.blur(wallpaper, radius: 90, saturation: 1.4)
        // From the same `now` as the resets in the hover card, so the frame agrees with itself; set TZ to pick the hour.
        clock = (NSAttributedString(string: Self.clockText(now), attributes: [.font: NSFont.systemFont(ofSize: 13)]), .zero)
        layOutBar()
        measure()
        cardBackdrop = makeCardBackdrop()
    }

    /// The demo pool a few minutes of work later: the busiest login spent a little more, which
    /// comes back with its reset, the pool's biggest.
    private static func later(_ store: PoolStore, connection: ProxyConnection, sessionFree: Double, pool: Double) -> PoolStore {
        var state = store.state
        let claude = ClaudeProvider().proxyName
        if var session = state.summaries[claude]?.session {
            if let biggest = session.resets.indices.max(by: { session.resets[$0].gain < session.resets[$1].gain }) {
                session.resets[biggest].gain += session.freePercent - pool
            }
            session.freePercent = pool
            state.summaries[claude]?.session = session
        }
        if let index = state.details.firstIndex(where: { $0.provider == claude && $0.plan?.weight.session == 20 }) {
            state.details[index].sessionFree = sessionFree
        }
        return PoolStore(connection: connection, state: state, proxyReadAt: store.proxyReadAt, strongestUrgency: store.strongestUrgency, incidents: store.incidents)
    }

    // MARK: Layout

    /// Status items from the right edge: the clock, Control Center, Spotlight, Wi-Fi, battery,
    /// sound, then Ebb.
    private func layOutBar() {
        let slot: CGFloat = 8
        var right = Self.screen.width - 12
        let clockSize = clock.text.size()
        clock.origin = CGPoint(x: right - clockSize.width, y: (Self.barHeight - clockSize.height) / 2)
        right -= clockSize.width + slot * 2
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent", "speaker.wave.2.fill"] {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { continue }
            let size = image.size
            glyphs.append((image, CGRect(x: right - size.width, y: ((Self.barHeight - size.height) / 2).rounded(), width: size.width, height: size.height)))
            right -= size.width + slot * 2
        }
        let size = readings[0].size
        item = CGRect(x: (right - size.width).rounded(), y: 1, width: size.width, height: size.height)
        panelOrigin = CGPoint(x: highlight.minX, y: Self.barHeight + 5)
    }

    /// The item's pressed background, which the panel hangs from.
    private var highlight: CGRect {
        item.insetBy(dx: -7, dy: 0.5)
    }

    func inPanel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: panelOrigin.x + point.x, y: panelOrigin.y + point.y)
    }

    var cardBottom: CGFloat {
        cardFrame(panel: CGRect(origin: panelOrigin, size: size(of: expanded[0]))).body.maxY
    }

    private func size(of image: CGImage) -> CGSize {
        CGSize(width: CGFloat(image.width) / Self.layerScale, height: CGFloat(image.height) / Self.layerScale)
    }

    /// Finds the rows to animate from where the collapsed and expanded panels have ink.
    private func measure() {
        let small = Ink(collapsed, scale: Self.layerScale)
        let width = size(of: collapsed).width
        let rows = small.bands(in: CGRect(origin: .zero, size: size(of: collapsed)), gap: 3)
        // Provider picker, titles, numbers, meters, pace line, Accounts, divider, footer.
        guard let divider = rows.lastIndex(where: { $0.height < 2 }), divider >= 4 else {
            fatalError("Recorder: the collapsed panel no longer has the rows it slices; update measure()")
        }
        let disclosure = rows[divider - 1]
        let pace = rows[divider - 2]
        let numbers = rows[divider - 4]
        topCut = disclosure.maxY + 3
        dividerTop = rows[divider].minY
        chevron = (small.bands(in: disclosure.insetBy(dx: 0, dy: -1), gap: 4, vertical: true).last ?? .zero).insetBy(dx: -3, dy: -3)
        rowRect = CGRect(x: disclosure.minX - 6, y: disclosure.midY - 11.5, width: disclosure.width + 12, height: 23)
        labelRect = small.bands(in: CGRect(x: 0, y: pace.minY - 1, width: width / 2, height: pace.height + 2), gap: 6, vertical: true).first ?? pace
        let changed = Ink.changes(expanded[0], expanded[1], in: CGRect(x: 0, y: numbers.minY, width: width / 2, height: numbers.height), scale: Self.layerScale)
        guard changed.width > 0 else { fatalError("Recorder: the 5-hour number didn't change between readings") }
        digit = CGRect(x: changed.minX - 2, y: numbers.minY - 6, width: changed.width + 4, height: numbers.height + 12)
        let pixels = CGRect(x: digit.minX * Self.layerScale, y: digit.minY * Self.layerScale, width: digit.width * Self.layerScale, height: digit.height * Self.layerScale).integral
        digit = CGRect(x: pixels.minX / Self.layerScale, y: pixels.minY / Self.layerScale, width: pixels.width / Self.layerScale, height: pixels.height / Self.layerScale)
        digits = expanded.compactMap { $0.cropping(to: pixels) }.map { ($0, Self.blur($0, radius: 5, saturation: 1)) }

        let big = Ink(expanded[0], scale: Self.layerScale)
        let full = big.bands(in: CGRect(origin: .zero, size: size(of: expanded[0])), gap: 3)
        let bottom = full.last { $0.height < 2 }?.minY ?? size(of: expanded[0]).height
        accountBands = full.filter { $0.minY > topCut && $0.maxY < bottom }
        accountsBottom = bottom - 2
    }

    func visibleRect(_ camera: Camera, size: CGSize) -> CGRect {
        let width = size.width / camera.zoom
        let height = size.height / camera.zoom
        let x = min(max(camera.focus.x - width / 2, 0), Self.screen.width - width)
        let y = min(max(camera.focus.y - height / 2, 0), Self.screen.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Drawing

    func render(_ shot: Shot, size: CGSize, visible: CGRect) -> CGImage {
        let context = Self.canvas(size)
        let zoom = size.width / visible.width
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }

        context.interpolationQuality = .high
        let screen = CGRect(origin: .zero, size: Self.screen)
        Self.draw(wallpaper, in: screen, context: context)
        if shot.depth > 0 {
            context.setAlpha(shot.depth * 0.7)
            Self.draw(blurredWallpaper, in: screen, context: context)
            context.setAlpha(1)
        }
        let panel = panelState(shot)
        drawBar(in: context, shot: shot, highlight: panel?.opacity ?? 0)
        if let panel {
            drawPanel(panel, shot: shot, in: context, zoom: zoom)
        }
        if let pointer = shot.pointer {
            drawPointer(at: pointer, press: shot.press, in: context, zoom: zoom)
        }
        return context.makeImage()!
    }

    private struct PanelState {
        var opacity: Double
        var scale: CGFloat
        var lift: CGFloat
    }

    /// Fades in and grows from the item, the way macOS shows a status item's window.
    private func panelState(_ shot: Shot) -> PanelState? {
        guard let opened = shot.opened else { return nil }
        let grow = Ease.spring(opened, response: 0.3, damping: 0.86)
        return PanelState(opacity: Ease.out(opened / 0.16), scale: 0.95 + 0.05 * grow, lift: -5 * (1 - grow))
    }

    private var barInk: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.84)
    }

    private func drawBar(in context: CGContext, shot: Shot, highlight amount: Double) {
        if amount > 0 {
            context.setFillColor(isDark ? CGColor(gray: 1, alpha: 0.2 * amount) : CGColor(gray: 0, alpha: 0.1 * amount))
            context.addPath(CGPath(roundedRect: highlight, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
            context.fillPath()
        }
        // The menu bar redraws the item at once; this only softens the swap over a few frames.
        let swap = shot.ticked.map { min($0 / 0.08, 1) } ?? 1
        if swap < 1 {
            tint(readings[shot.reading - 1], in: item, alpha: 1 - swap, context: context)
        }
        tint(readings[shot.reading], in: item, alpha: swap, context: context)
        for glyph in glyphs {
            tint(glyph.image, in: glyph.rect, alpha: 1, context: context)
        }
        let text = NSMutableAttributedString(attributedString: clock.text)
        text.addAttribute(.foregroundColor, value: barInk, range: NSRange(location: 0, length: text.length))
        text.draw(at: clock.origin)
    }

    /// What the menu bar does with a template image: its alpha, in the bar's ink.
    private func tint(_ image: NSImage, in rect: CGRect, alpha: Double, context: CGContext) {
        let bounds = rect.insetBy(dx: -2, dy: -2)
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if image.isTemplate {
            context.setBlendMode(.sourceIn)
            context.setFillColor(barInk.cgColor)
            context.fill(bounds)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawPanel(_ state: PanelState, shot: Shot, in context: CGContext, zoom: CGFloat) {
        let collapsedHeight = size(of: collapsed).height
        let expandedHeight = size(of: expanded[0]).height
        let height = collapsedHeight + (expandedHeight - collapsedHeight) * (shot.expanded.map(Ease.reveal) ?? 0)
        let frame = CGRect(x: panelOrigin.x, y: panelOrigin.y, width: size(of: collapsed).width, height: height)
        let shape = CGPath(roundedRect: frame, cornerWidth: 5, cornerHeight: 5, transform: nil)

        context.saveGState()
        let anchor = CGPoint(x: item.midX, y: panelOrigin.y)
        context.translateBy(x: anchor.x, y: anchor.y + state.lift)
        context.scaleBy(x: state.scale, y: state.scale)
        context.translateBy(x: -anchor.x, y: -anchor.y)
        context.setAlpha(state.opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        // Window shadow: a wide soft one and a tight contact one. Shadows ignore the zoom.
        context.setShadow(offset: CGSize(width: 0, height: -14 * zoom), blur: 36 * zoom, color: CGColor(gray: 0, alpha: isDark ? 0.55 : 0.2))
        context.addPath(shape)
        context.setFillColor(.black)
        context.fillPath()
        context.setShadow(offset: CGSize(width: 0, height: -1 * zoom), blur: 3 * zoom, color: CGColor(gray: 0, alpha: isDark ? 0.4 : 0.12))
        context.addPath(shape)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        context.saveGState()
        context.addPath(shape)
        context.clip()
        Self.draw(blurredWallpaper, in: CGRect(origin: .zero, size: Self.screen), context: context)
        context.setFillColor(isDark ? CGColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.84) : CGColor(srgbRed: 0.97, green: 0.975, blue: 0.98, alpha: 0.8))
        context.fill(frame)
        if shot.rowHover > 0 {
            context.setFillColor(CGColor(gray: isDark ? 1 : 0, alpha: (isDark ? 0.1 : 0.07) * shot.rowHover))
            context.addPath(CGPath(roundedRect: rowRect.offsetBy(dx: frame.minX, dy: frame.minY), cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
        }
        if let expanded = shot.expanded, expanded < 1.2 {
            drawExpansion(at: expanded, height: height, frame: frame, in: context)
        } else if shot.expanded == nil {
            Self.draw(collapsed, in: CGRect(origin: frame.origin, size: size(of: collapsed)), context: context)
        } else if let ticked = shot.ticked, ticked < 0.7 {
            drawTick(to: shot.reading, at: ticked, frame: frame, in: context)
        } else {
            Self.draw(expanded[shot.reading], in: frame, context: context)
        }
        if shot.labelHover > 0 {
            drawUnderline(in: context, frame: frame, alpha: shot.labelHover)
        }
        context.restoreGState()

        // A hairline outside, a lighter edge inside.
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: -0.25, dy: -0.25), cornerWidth: 5.25, cornerHeight: 5.25, transform: nil))
        context.setStrokeColor(CGColor(gray: 0, alpha: isDark ? 0.7 : 0.14))
        context.setLineWidth(0.5)
        context.strokePath()
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: isDark ? 0.13 : 0.55))
        context.setLineWidth(1)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()

        if let opened = shot.cardOpened, shot.cardClosed.map({ $0 < 0.14 }) ?? true {
            drawCard(opened: opened, closed: shot.cardClosed, panel: frame, in: context, zoom: zoom)
        }
    }

    /// The accounts opening: the panel grows on `Motion.reveal`, the chevron turns, rows fade and
    /// settle 0.03 s apart, and the footer rides the bottom edge.
    private func drawExpansion(at time: Double, height: CGFloat, frame: CGRect, in context: CGContext) {
        let width = frame.width
        let collapsedHeight = size(of: collapsed).height
        let origin = frame.origin
        Self.draw(collapsed, from: CGRect(x: 0, y: 0, width: width, height: chevron.minY), at: origin, context: context)
        Self.draw(collapsed, from: CGRect(x: 0, y: chevron.minY, width: chevron.minX, height: topCut - chevron.minY), at: CGPoint(x: origin.x, y: origin.y + chevron.minY), context: context)
        Self.draw(collapsed, from: CGRect(x: chevron.maxX, y: chevron.minY, width: width - chevron.maxX, height: topCut - chevron.minY), at: CGPoint(x: origin.x + chevron.maxX, y: origin.y + chevron.minY), context: context)

        context.saveGState()
        let center = CGPoint(x: origin.x + chevron.midX, y: origin.y + chevron.midY)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .pi / 2 * Ease.reveal(time))
        context.translateBy(x: -center.x, y: -center.y)
        Self.draw(collapsed, from: chevron, at: CGPoint(x: origin.x + chevron.minX, y: origin.y + chevron.minY), context: context)
        context.restoreGState()

        let grown = height - collapsedHeight
        context.saveGState()
        context.clip(to: CGRect(x: origin.x, y: origin.y + topCut, width: width, height: max(min(accountsBottom, dividerTop + grown - 2) - topCut, 0)))
        let section = Ease.reveal(time)
        for (index, band) in accountBands.enumerated() {
            let settle = Ease.reveal(time - Motion.stagger * Double(index))
            context.setAlpha(min(max(section * settle, 0), 1))
            Self.draw(expanded[0], from: band.insetBy(dx: -2, dy: -2), at: CGPoint(x: origin.x + band.minX - 2, y: origin.y + band.minY - 2 - 5 * (1 - settle)), context: context)
        }
        context.restoreGState()
        Self.draw(collapsed, from: CGRect(x: 0, y: topCut, width: width, height: collapsedHeight - topCut), at: CGPoint(x: origin.x, y: origin.y + topCut + grown), context: context)
    }

    /// A new reading: meters and rows ease across on `.smooth`, and the changed digit of the big
    /// number rolls down, blurring as it moves, as SwiftUI's numeric text does when a value falls.
    private func drawTick(to reading: Int, at time: Double, frame: CGRect, in context: CGContext) {
        let old = expanded[reading - 1], new = expanded[reading]
        let progress = min(Ease.smooth(time), 1)
        let slot = digit.offsetBy(dx: frame.minX, dy: frame.minY)
        // Adding the two weighted layers keeps what both share at full strength.
        context.saveGState()
        context.addRect(frame)
        context.addRect(slot)
        context.clip(using: .evenOdd)
        context.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
        context.setAlpha(1 - progress)
        Self.draw(old, in: frame, context: context)
        context.setAlpha(progress)
        context.setBlendMode(.plusLighter)
        Self.draw(new, in: frame, context: context)
        context.endTransparencyLayer()
        context.restoreGState()

        context.saveGState()
        context.clip(to: slot)
        let travel = digit.height * 0.4
        let blur = sin(.pi * progress)
        for (image, offset, alpha) in [
            (digits[reading - 1], travel * progress, max(1 - progress * 2, 0)),
            (digits[reading], -travel * (1 - progress), min(max(progress * 2 - 0.5, 0), 1)),
        ] {
            let rect = slot.offsetBy(dx: 0, dy: offset)
            context.setAlpha(alpha * (1 - blur))
            Self.draw(image.sharp, in: rect, context: context)
            context.setAlpha(alpha * blur)
            Self.draw(image.blurred, in: rect, context: context)
        }
        context.restoreGState()
    }

    private func drawUnderline(in context: CGContext, frame: CGRect, alpha: Double) {
        let y = frame.minY + labelRect.maxY + 2.2
        context.saveGState()
        context.setStrokeColor(CGColor(gray: isDark ? 1 : 0, alpha: (isDark ? 0.5 : 0.45) * alpha))
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [0.01, 2.2])
        context.move(to: CGPoint(x: frame.minX + labelRect.minX + 0.5, y: y))
        context.addLine(to: CGPoint(x: frame.minX + labelRect.maxX, y: y))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Hover card

    private func cardFrame(panel: CGRect) -> (body: CGRect, tip: CGPoint) {
        let cardSize = size(of: card)
        let tip = CGPoint(x: panel.minX + labelRect.midX, y: panel.minY + labelRect.maxY + 6)
        let body = CGRect(x: (tip.x - cardSize.width / 2).rounded(), y: tip.y + 9, width: cardSize.width, height: cardSize.height)
        return (body, tip)
    }

    private func cardShape(body: CGRect, tip: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let radius: CGFloat = 10
        let half: CGFloat = 11
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: tip.x - half, y: body.minY))
        path.addCurve(to: tip, control1: CGPoint(x: tip.x - half / 2, y: body.minY), control2: CGPoint(x: tip.x - 2.2, y: tip.y))
        path.addCurve(to: CGPoint(x: tip.x + half, y: body.minY), control1: CGPoint(x: tip.x + 2.2, y: tip.y), control2: CGPoint(x: tip.x + half / 2, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: tip.x - half, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    /// The panel with its accounts open, blurred, for the card's material.
    private func makeCardBackdrop() -> (CGImage, CGRect)? {
        let (body, tip) = cardFrame(panel: CGRect(origin: panelOrigin, size: size(of: expanded[0])))
        let rect = body.union(CGRect(origin: tip, size: .zero)).insetBy(dx: -40, dy: -40)
        let image = render(Script.hero, size: CGSize(width: rect.width * 2, height: rect.height * 2), visible: rect)
        return (Self.blur(image, radius: 30, saturation: 1.3), rect)
    }

    /// Scales up from the arrow as it fades in, the way a popover appears; fades out.
    private func drawCard(opened: Double, closed: Double?, panel: CGRect, in context: CGContext, zoom: CGFloat) {
        let (body, tip) = cardFrame(panel: panel)
        let shape = cardShape(body: body, tip: tip)
        let scale = 0.9 + 0.1 * Ease.spring(opened, response: 0.32, damping: 0.78)
        let opacity = Ease.out(opened / 0.15) * (closed.map { 1 - Ease.inOut($0 / 0.14) } ?? 1)

        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -tip.x, y: -tip.y)
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: CGSize(width: 0, height: -8 * zoom), blur: 24 * zoom, color: CGColor(gray: 0, alpha: isDark ? 0.5 : 0.18))
        context.addPath(shape)
        context.setFillColor(.black)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let cardBackdrop {
            Self.draw(cardBackdrop.image, in: cardBackdrop.rect, context: context)
        }
        context.setFillColor(isDark ? CGColor(srgbRed: 0.19, green: 0.195, blue: 0.21, alpha: 0.84) : CGColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 0.84))
        context.fill(body.union(CGRect(origin: tip, size: .zero)))
        Self.draw(card, in: body, context: context)
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: isDark ? 0.14 : 0.6))
        context.setLineWidth(1)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Pointer

    /// The macOS arrow: black with a white rim and a soft shadow. Pressing shrinks it a touch.
    private func drawPointer(at point: CGPoint, press: Double, in context: CGContext, zoom: CGFloat) {
        let arrow = CGMutablePath()
        arrow.addLines(between: [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15.2), CGPoint(x: 3.6, y: 11.9), CGPoint(x: 6.1, y: 17.6),
            CGPoint(x: 8.4, y: 16.6), CGPoint(x: 5.9, y: 11.0), CGPoint(x: 10.6, y: 11.0),
        ])
        arrow.closeSubpath()
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1 - 0.1 * press, y: 1 - 0.1 * press)
        context.translateBy(x: 1.3, y: 1.6)
        context.setLineJoin(.round)
        context.setShadow(offset: CGSize(width: 0, height: -1.4 * zoom), blur: 3 * zoom, color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(arrow)
        context.setStrokeColor(.white)
        context.setLineWidth(2.6)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(arrow)
        context.setFillColor(.white)
        context.fillPath()
        context.addPath(arrow)
        context.setFillColor(.black)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Images

    /// A view drawn offscreen at 3x on a clear background, every animation finished.
    private static func render(_ view: some View, width: CGFloat, scheme: ColorScheme) -> CGImage {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        settle(host)
        window.setContentSize(host.fittingSize)
        settle(host)
        let bounds = host.bounds
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * layerScale), pixelsHigh: Int(bounds.height * layerScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        window.close()
        return rep.cgImage!
    }

    private static func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.15)
        }
    }

    /// A flipped sRGB canvas: points from the top left, like the views.
    private static func canvas(_ size: CGSize) -> CGContext {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Draws the part of a 3x layer under `source`, in points, with its top left at `origin`.
    private static func draw(_ image: CGImage, from source: CGRect, at origin: CGPoint, context: CGContext) {
        let pixels = CGRect(x: source.minX * layerScale, y: source.minY * layerScale, width: source.width * layerScale, height: source.height * layerScale).integral
        guard let part = image.cropping(to: pixels) else { return }
        let rect = CGRect(x: origin.x + (pixels.minX / layerScale - source.minX), y: origin.y + (pixels.minY / layerScale - source.minY), width: pixels.width / layerScale, height: pixels.height / layerScale)
        draw(part, in: rect, context: context)
    }

    private static func blur(_ image: CGImage, radius: Double, saturation: Double) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)!
    }

    /// Ebb's tide at night or by day: swells stacked toward the viewer, each lit along its crest
    /// and casting a soft shadow on the one behind, under a sky that glows where the light is.
    private static func wallpaper(isDark: Bool) -> CGImage {
        let scale: CGFloat = 3
        let context = canvas(CGSize(width: screen.width * scale, height: screen.height * scale))
        context.scaleBy(x: scale, y: scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ colors: [CGColor]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        }
        func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let light = CGPoint(x: 400, y: 280)
        let sky = isDark ? [rgb(0x060D1C), rgb(0x0E2648)] : [rgb(0xE6EFF9), rgb(0xD0E3F4)]
        context.drawLinearGradient(gradient(sky), start: .zero, end: CGPoint(x: 0, y: 420), options: [.drawsAfterEndLocation])
        let glow = isDark ? rgb(0x4A8AD0, 0.62) : rgb(0xFFF8EE, 1)
        context.drawRadialGradient(gradient([glow, glow.copy(alpha: 0)!]), startCenter: light, startRadius: 0, endCenter: light, endRadius: 520, options: [])

        // Crest color at the lit edge, then deep color, back to front.
        let layers: [(top: Int, deep: Int)] = isDark
            ? [(0x2B62A0, 0x0F2A4E), (0x22548E, 0x0C2343), (0x1B4880, 0x0A1D39), (0x163C6E, 0x08172E), (0x10305C, 0x061224), (0x0B2449, 0x040D1B)]
            : [(0xDDEBF7, 0xC3DAEE), (0xC7DEF2, 0xA9CAEA), (0xADCDEC, 0x8DB8E1), (0x93BCE4, 0x74A6D8), (0x79AADB, 0x5D94CD), (0x6299D1, 0x4882C1)]
        let rim = isDark ? 0x9CCBFF : 0xFFFFFF
        for (index, layer) in layers.enumerated() {
            let depth = CGFloat(index)
            let base = 225 + depth * 62
            let amplitude = 22 + depth * 5
            let length = 150 + depth * 22
            let phase = Double(index) * 1.9 + 0.6
            var crest: [CGPoint] = []
            for x in stride(from: CGFloat(-20), through: screen.width + 20, by: 4) {
                let swell = 0.8 * sin(Double(x / length) + phase) + 0.2 * sin(Double(x / (length * 0.45)) + phase * 2.3)
                crest.append(CGPoint(x: x, y: base + 0.13 * (x - 500) + amplitude * CGFloat(swell)))
            }
            let line = CGMutablePath()
            line.addLines(between: crest)
            let body = line.mutableCopy()!
            body.addLine(to: CGPoint(x: screen.width + 20, y: screen.height + 20))
            body.addLine(to: CGPoint(x: -20, y: screen.height + 20))
            body.closeSubpath()

            // A shadow cast up onto the swell behind.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 6 * scale), blur: 34 * scale, color: isDark ? rgb(0x000000, 0.55) : rgb(0x1C3D66, 0.22))
            context.addPath(body)
            context.setFillColor(rgb(layer.deep))
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(body)
            context.clip()
            let top = base - 0.13 * 500 - amplitude
            context.drawLinearGradient(gradient([rgb(layer.top), rgb(layer.deep)]), start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top + 230), options: [.drawsAfterEndLocation])
            // Light along the lip, softest wide and brightest near the glow.
            for (width, alpha) in [(18.0, 0.05), (9.0, 0.08), (4.0, 0.12), (1.2, isDark ? 0.32 : 0.7)] as [(CGFloat, CGFloat)] {
                context.saveGState()
                context.addPath(line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
                context.clip()
                let near = CGPoint(x: light.x, y: base)
                context.drawRadialGradient(gradient([rgb(rim, alpha), rgb(rim, alpha * 0.2)]), startCenter: near, startRadius: 0, endCenter: near, endRadius: 640, options: [.drawsAfterEndLocation])
                context.restoreGState()
            }
            context.restoreGState()
        }

        // Seeded, so every run draws the same grain.
        var seed: UInt32 = 0x2545_F491
        let side = 256
        let grain = (0..<side * side).map { _ -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(seed >> 24)
        }
        if let provider = CGDataProvider(data: Data(grain) as CFData),
           let noise = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            context.setAlpha(isDark ? 0.035 : 0.025)
            context.setBlendMode(.overlay)
            context.draw(noise, in: CGRect(x: 0, y: 0, width: CGFloat(side) / scale, height: CGFloat(side) / scale), byTiling: true)
        }
        return context.makeImage()!
    }
}

/// Where a layer has ink: rows of content split by empty gaps, in points.
private struct Ink {
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private var alpha: [UInt8]

    init(_ image: CGImage, scale: CGFloat) {
        width = image.width
        height = image.height
        self.scale = scale
        alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Content inside `rect` split where at least `gap` points stay empty: rows top to bottom,
    /// or with `vertical`, columns left to right.
    func bands(in rect: CGRect, gap: CGFloat, vertical: Bool = false) -> [CGRect] {
        let x0 = max(Int(rect.minX * scale), 0), x1 = min(Int(rect.maxX * scale), width)
        let y0 = max(Int(rect.minY * scale), 0), y1 = min(Int(rect.maxY * scale), height)
        let isInk = { (x: Int, y: Int) in alpha[y * width + x] > 10 }
        var runs: [(start: Int, end: Int)] = []
        for line in vertical ? Array(x0..<x1) : Array(y0..<y1) {
            let hasInk = vertical ? (y0..<y1).contains { isInk(line, $0) } : (x0..<x1).contains { isInk($0, line) }
            guard hasInk else { continue }
            if let last = runs.last, line - last.end <= Int(gap * scale) {
                runs[runs.count - 1].end = line
            } else {
                runs.append((line, line))
            }
        }
        return runs.map { run in
            let inked = (vertical ? Array(y0..<y1) : Array(x0..<x1)).filter { position in
                (run.start...run.end).contains { vertical ? isInk($0, position) : isInk(position, $0) }
            }
            let low = CGFloat(inked.first ?? 0) / scale, high = CGFloat((inked.last ?? 0) + 1) / scale
            let start = CGFloat(run.start) / scale, end = CGFloat(run.end + 1) / scale
            return vertical ? CGRect(x: start, y: low, width: end - start, height: high - low) : CGRect(x: low, y: start, width: high - low, height: end - start)
        }
    }

    /// The bounds of every pixel inside `rect` that differs between two layers of the same size.
    static func changes(_ a: CGImage, _ b: CGImage, in rect: CGRect, scale: CGFloat) -> CGRect {
        guard a.width == b.width, a.height == b.height else { fatalError("Recorder: the panel changed size between readings") }
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let first = pixels(a), second = pixels(b)
        var bounds = CGRect.null
        for y in max(Int(rect.minY * scale), 0)..<min(Int(rect.maxY * scale), a.height) {
            for x in max(Int(rect.minX * scale), 0)..<min(Int(rect.maxX * scale), a.width) {
                let index = (y * a.width + x) * 4
                if (0..<4).contains(where: { abs(Int(first[index + $0]) - Int(second[index + $0])) > 24 }) {
                    bounds = bounds.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
                }
            }
        }
        return bounds.isNull ? .zero : bounds
    }
}
