import AppKit
import CoreText
import EbbCore

/// Draws a `MenuBarItem` as a single image, so the mark, the 3 pt gap and the type land
/// exactly as designed. Plain states are template images that the menu bar tints like its
/// own items. Tinted states can't be templates, so their drawing handler resolves colours
/// against the appearance it draws in.
@MainActor
enum MenuBarImage {
    nonisolated static let height: CGFloat = 22

    private static var last: (item: MenuBarItem, image: NSImage)?

    /// The same image for the same item, so the status item only redraws when something changed.
    static func cached(_ item: MenuBarItem) -> NSImage {
        if let last, last.item == item { return last.image }
        let image = make(item)
        last = (item, image)
        return image
    }

    /// `appearance` pins the colours, for previews; `nil` follows wherever the image is drawn.
    static func make(_ item: MenuBarItem, appearance: NSAppearance? = nil) -> NSImage {
        let layout = Layout(item)
        let isTemplate = !item.isTinted
        let image = NSImage(size: NSSize(width: layout.width, height: height), flipped: true) { _ in
            // AppKit may call this on any thread that draws the image, so nothing in it is actor-bound.
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let draw = { layout.draw(in: context, palette: Palette(isTemplate: isTemplate), dimmed: item.isStale) }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = item.accessibilityLabel
        return image
    }
}

/// Colours for one drawing pass. Templates draw black and let the menu bar tint them.
private struct Palette {
    let label: CGColor
    let orange: CGColor
    /// Behind white text at 5% or less.
    let capsule: CGColor
    /// Fills and arcs at 5% or less: a darker red in light mode, where it stands without white text.
    let red: CGColor

    init(isTemplate: Bool) {
        let match = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let isDark = match == .darkAqua || match == .vibrantDark
        label = isTemplate ? NSColor.black.cgColor : NSColor.labelColor.cgColor
        orange = isDark ? Self.rgb(0xFF9F0A) : Self.rgb(0xC93400)
        capsule = isDark ? Self.rgb(0xFF453A) : Self.rgb(0xFF3B30)
        red = isDark ? Self.rgb(0xFF453A) : Self.rgb(0xD70015)
    }

    func fill(_ state: LowState) -> CGColor {
        switch state {
        case .normal: label
        case .low: orange
        case .critical: red
        }
    }

    func text(_ state: LowState) -> CGColor {
        state == .low ? orange : label
    }

    /// The label colour at a share of its own opacity: secondary text, tracks, grey dots.
    func label(times factor: CGFloat) -> CGColor {
        label.copy(alpha: label.alpha * factor) ?? label
    }

    private static func rgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Sizes every part up front, so the image knows its width before it draws.
private struct Layout {
    private enum Piece {
        case mark(x: CGFloat, percent: Int, state: LowState)
        case line(x: CGFloat, runs: [Text])
        case stack(x: CGFloat, width: CGFloat, rows: [StackRow])
        case ring(x: CGFloat, ring: MenuBarItem.Ring)
        case bars(x: CGFloat, session: MenuBarItem.Gauge, weekly: MenuBarItem.Gauge)
    }

    private struct Text {
        let line: CTLine
        let width: CGFloat
        let state: LowState
        let isSecondary: Bool

        /// Text at 5% or less sits on a capsule 4 pt wider each side that overlaps its gaps by 1 pt.
        var slotWidth: CGFloat { state == .critical ? width + 6 : width }
    }

    private struct StackRow {
        let label: Text
        let value: Text
        let refill: Text?
    }

    private static let partGap: CGFloat = 3
    private static let runGap: CGFloat = 4
    private static let markSize: CGFloat = 16
    private static let ringSize: CGFloat = 22
    private static let barsWidth: CGFloat = 10
    private static let stackRowHeight: CGFloat = 10

    private(set) var width: CGFloat = 0
    private var pieces: [Piece] = []
    private var origin: CGFloat = 0

    init(_ item: MenuBarItem) {
        var x: CGFloat = 0
        var minX: CGFloat = 0
        var maxX: CGFloat = 0
        for (index, part) in item.parts.enumerated() {
            if index > 0 { x += Self.partGap }
            switch part {
            case let .mark(percent, state):
                pieces.append(.mark(x: x, percent: percent, state: state))
                x += Self.markSize
            case let .line(runs):
                let texts = runs.map { run in
                    let font = run.state == .critical ? Fonts.capsule : Fonts.body
                    return Self.text(run.text, font: font, state: run.state, isSecondary: run.isSecondary)
                }
                pieces.append(.line(x: x, runs: texts))
                for (runIndex, text) in texts.enumerated() {
                    if runIndex > 0 { x += Self.runGap }
                    if text.state == .critical { minX = min(minX, x - 1) }
                    x += text.slotWidth
                    if text.state == .critical { maxX = max(maxX, x + 1) }
                }
            case let .stack(rows):
                x += 1
                let built = rows.map { row in
                    StackRow(
                        label: Self.text(row.label, font: Fonts.stack, state: .normal, isSecondary: true),
                        value: Self.text(row.value, font: row.state == .critical ? Fonts.stackCapsule : Fonts.stack, state: row.state, isSecondary: false),
                        refill: row.refill.map { Self.text($0, font: Fonts.stack, state: .normal, isSecondary: true) }
                    )
                }
                let width = built.map(Self.rowWidth).max() ?? 0
                pieces.append(.stack(x: x, width: width, rows: built))
                x += width
            case let .ring(ring):
                pieces.append(.ring(x: x, ring: ring))
                x += Self.ringSize
            case let .bars(session, weekly):
                pieces.append(.bars(x: x, session: session, weekly: weekly))
                x += Self.barsWidth
            }
            maxX = max(maxX, x)
        }
        origin = -minX
        width = ceil(maxX - minX)
    }

    private static func text(_ string: String, font: CTFont, state: LowState, isSecondary: Bool) -> Text {
        let line = Fonts.line(string, font: font)
        return Text(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), state: state, isSecondary: isSecondary)
    }

    private static func rowWidth(_ row: StackRow) -> CGFloat {
        let value = row.value.state == .critical ? row.value.width + 4 : row.value.width
        return row.label.width + 3 + value + (row.refill.map { 3 + $0.width } ?? 0)
    }

    // MARK: - Drawing

    func draw(in context: CGContext, palette: Palette, dimmed: Bool) {
        let scale = abs(context.userSpaceToDeviceSpaceTransform.a)
        context.saveGState()
        if dimmed {
            // One layer, so where an arc or fill crosses its track the whole item is still at half.
            context.setAlpha(0.5)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.translateBy(x: origin, y: 0)
        for piece in pieces {
            switch piece {
            case let .mark(x, percent, state):
                drawMark(at: x, percent: percent, state: state, in: context, palette: palette)
            case let .line(x, runs):
                drawLine(runs, at: x, in: context, palette: palette)
            case let .stack(x, width, rows):
                drawStack(rows, at: x, width: width, in: context, palette: palette)
            case let .ring(x, ring):
                drawRing(ring, at: x, scale: scale, in: context, palette: palette)
            case let .bars(x, session, weekly):
                drawBar(session, at: x, in: context, palette: palette)
                drawBar(weekly, at: x + 6, in: context, palette: palette)
            }
        }
        if dimmed { context.endTransparencyLayer() }
        context.restoreGState()
    }

    private func drawMark(at x: CGFloat, percent: Int, state: LowState, in context: CGContext, palette: Palette) {
        let rect = CGRect(x: x, y: (MenuBarImage.height - Self.markSize) / 2, width: Self.markSize, height: Self.markSize)
        // Empty leaves no water to tint, so the warning moves to the ring.
        context.setFillColor(percent == 0 && state == .critical ? palette.red : palette.label)
        context.addPath(EbbRing().path(in: rect).cgPath)
        context.fillPath(using: .evenOdd)
        context.setFillColor(palette.fill(state))
        context.addPath(EbbWater(level: Double(percent) / 100).path(in: rect).cgPath)
        context.fillPath()
    }

    private func drawLine(_ runs: [Text], at start: CGFloat, in context: CGContext, palette: Palette) {
        var x = start
        for (index, run) in runs.enumerated() {
            if index > 0 { x += Self.runGap }
            let lineBox = Fonts.bodySize
            let top = (MenuBarImage.height - lineBox) / 2
            if run.state == .critical {
                // A 1 pt top and 2 pt bottom pad centres the capsule on the type, not on the line box.
                let capsule = CGRect(x: x - 1, y: top - 1, width: run.width + 8, height: lineBox + 3)
                context.setFillColor(palette.capsule)
                context.addPath(CGPath(roundedRect: capsule, cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.fillPath()
                context.setFillColor(.white)
                Self.draw(run.line, x: x + 3, baseline: top + Self.baselineOffset(Fonts.capsule, lineBox: lineBox), in: context)
            } else {
                context.setFillColor(run.isSecondary ? palette.label(times: 0.55) : palette.text(run.state))
                Self.draw(run.line, x: x, baseline: top + Self.baselineOffset(Fonts.body, lineBox: lineBox), in: context)
            }
            x += run.slotWidth
        }
    }

    private func drawStack(_ rows: [StackRow], at x: CGFloat, width: CGFloat, in context: CGContext, palette: Palette) {
        let lineBox = Self.stackRowHeight
        var top = (MenuBarImage.height - lineBox * CGFloat(rows.count)) / 2
        for row in rows {
            let baseline = top + Self.baselineOffset(Fonts.stack, lineBox: lineBox)
            context.setFillColor(palette.label(times: 0.55))
            Self.draw(row.label.line, x: x, baseline: baseline, in: context)

            var right = x + width
            if let refill = row.refill {
                right -= refill.width
                context.setFillColor(palette.label(times: 0.55))
                Self.draw(refill.line, x: right, baseline: baseline, in: context)
                right -= 3
            }
            if row.value.state == .critical {
                let capsule = CGRect(x: right - row.value.width - 4, y: top, width: row.value.width + 4, height: lineBox)
                context.setFillColor(palette.capsule)
                context.addPath(CGPath(roundedRect: capsule, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                context.setFillColor(.white)
                Self.draw(row.value.line, x: capsule.minX + 2, baseline: top + Self.baselineOffset(Fonts.stackCapsule, lineBox: lineBox), in: context)
            } else {
                context.setFillColor(palette.text(row.value.state))
                Self.draw(row.value.line, x: right - row.value.width, baseline: baseline, in: context)
            }
            top += lineBox
        }
    }

    /// Arc for the weekly window with a 104° gap at the bottom, the 5-hour number inside,
    /// and the accounts in the gap. Geometry on a 22 pt box: radius 8.4, stroke 1.7.
    private func drawRing(_ ring: MenuBarItem.Ring, at x: CGFloat, scale: CGFloat, in context: CGContext, palette: Palette) {
        let center = CGPoint(x: x + 11, y: 11)
        let radius: CGFloat = 8.4
        let start: CGFloat = 142 * .pi / 180
        let sweep: CGFloat = 256 * .pi / 180

        context.setLineWidth(1.7)
        context.setLineCap(.round)
        // An empty week leaves no arc to tint, so the track takes the warning.
        let isEmpty = ring.arc.percent == 0 && ring.arc.state == .critical
        context.setStrokeColor(isEmpty ? palette.red.copy(alpha: 0.5) ?? palette.red : palette.label(times: 0.3))
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
        context.strokePath()
        if ring.arc.percent > 0 {
            context.setStrokeColor(palette.fill(ring.arc.state))
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep * CGFloat(ring.arc.percent) / 100, clockwise: false)
            context.strokePath()
        }

        switch RingAccounts(ring.accounts, backingScale: Double(scale)) {
        case .hidden:
            break
        case let .dots(dots):
            // 20° apart, as drawn for four accounts; five close up so the outer dots clear the arc's caps.
            let step: CGFloat = min(20.12, 72 / CGFloat(max(dots.count - 1, 1)))
            for (index, isReady) in dots.enumerated() {
                let angle = (90 + (CGFloat(dots.count - 1) / 2 - CGFloat(index)) * step) * .pi / 180
                let dot = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                context.setFillColor(isReady ? palette.label : palette.label(times: 0.3))
                context.fillEllipse(in: CGRect(x: dot.x - 0.825, y: dot.y - 0.825, width: 1.65, height: 1.65))
            }
        case let .count(ready, total):
            let line = Fonts.line("\(ready)/\(total)", font: Fonts.ringCount)
            context.setFillColor(palette.label)
            Self.draw(line, centeredAt: center.x, baseline: 21.3, in: context)
        }

        let isFull = ring.number.percent == 100
        let line = Fonts.line("\(ring.number.percent)", font: isFull ? Fonts.ringFull : Fonts.ringNumber, kern: isFull ? -0.35 : -0.15)
        context.setFillColor(palette.fill(ring.number.state))
        Self.draw(line, centeredAt: center.x, baseline: isFull ? 13.2 : 13.888, in: context)
    }

    /// An upright 4 × 14 pt capsule that fills from the bottom.
    private func drawBar(_ gauge: MenuBarItem.Gauge, at x: CGFloat, in context: CGContext, palette: Palette) {
        let track = CGRect(x: x, y: (MenuBarImage.height - 16) / 2 + 1, width: 4, height: 14)
        let shape = CGPath(roundedRect: track, cornerWidth: 2, cornerHeight: 2, transform: nil)
        // An empty bar leaves no fill to tint, so the track takes the warning.
        let isEmpty = gauge.percent == 0 && gauge.state == .critical
        context.setFillColor(isEmpty ? palette.red.copy(alpha: 0.5) ?? palette.red : palette.label(times: 0.28))
        context.addPath(shape)
        context.fillPath()
        let height = track.height * CGFloat(gauge.percent) / 100
        guard height > 0 else { return }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(palette.fill(gauge.state))
        context.fill(CGRect(x: track.minX, y: track.maxY - height, width: track.width, height: height))
        context.restoreGState()
    }

    // MARK: - Type

    /// Where the baseline sits in a line box of `lineBox` points, with the font's
    /// ascent and descent centred in it.
    private static func baselineOffset(_ font: CTFont, lineBox: CGFloat) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        return (lineBox - ascent - descent) / 2 + ascent
    }

    private static func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat, in context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        // The image is flipped; Core Text draws with y growing upward.
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func draw(_ line: CTLine, centeredAt x: CGFloat, baseline: CGFloat, in context: CGContext) {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        draw(line, x: x - width / 2, baseline: baseline, in: context)
    }
}

/// Core Text fonts are immutable and thread-safe, so the drawing handler can read them from any thread.
private enum Fonts {
    static let bodySize: CGFloat = 13
    /// SF Pro with monospaced digits, so the item keeps its width as the number moves.
    nonisolated(unsafe) static let body = NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular) as CTFont
    nonisolated(unsafe) static let capsule = NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .medium) as CTFont
    nonisolated(unsafe) static let stack = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular) as CTFont
    nonisolated(unsafe) static let stackCapsule = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold) as CTFont
    nonisolated(unsafe) static let ringNumber = NSFont.compactRounded(size: 9.2, weight: 650) as CTFont
    nonisolated(unsafe) static let ringFull = NSFont.compactRounded(size: 7.4, weight: 650) as CTFont
    nonisolated(unsafe) static let ringCount = NSFont.compactRounded(size: 5.6, weight: 700) as CTFont

    /// Colour comes from the context's fill, so one line draws in any colour.
    static func line(_ string: String, font: CTFont, kern: CGFloat = 0) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kern,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }
}

extension NSFont {
    /// SF Compact Rounded with tabular digits: narrow enough for "88" inside the Ring.
    /// macOS ships it as a variable font without a public name, so it's read from its file;
    /// SF Pro Rounded stands in if the file ever moves.
    static func compactRounded(size: CGFloat, weight: CGFloat) -> NSFont {
        let tabular: [[CFString: Any]] = [[
            kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
        ]]
        let url = URL(fileURLWithPath: "/System/Library/Fonts/SFCompactRounded.ttf")
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let base = descriptors.first {
            let weightAxis = 0x7767_6874 // 'wght'
            let weighted = CTFontDescriptorCreateCopyWithVariation(base, weightAxis as CFNumber, weight)
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(weighted, [kCTFontFeatureSettingsAttribute: tabular] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        let system = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight >= 700 ? .bold : .semibold)
        let rounded = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
        return rounded ?? system
    }
}
