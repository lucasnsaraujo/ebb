import SwiftUI

/// The Ebb mark ("Tideline"): a ring holding water whose surface is one sine period.
///
/// Designed on a 16 × 16 pt grid, the status item's slot. Every number below is in grid
/// points and scales with the rect, so one shape draws the menu bar item and the popover header.
///
///     ring    centre (8, 8), outer radius 7.25, stroke 1.5, so inner radius 5.75
///     water   centre (8, 8), radius 4.9: the ring's inner edge less a 0.85 gap
///     surface y = base − a·sin(2π·(x − 3.1) / 9.8), base = 12.9 − 9.8·level
///             a = 0.7 · min(1, 3.2·level, 3.2·(1 − level)), flattening near empty and full
enum EbbMarkGeometry {
    static let grid: CGFloat = 16
    static let outerRadius: CGFloat = 7.25
    static let stroke: CGFloat = 1.5
    static let waterGap: CGFloat = 0.85
    static let amplitude: CGFloat = 0.7
    /// The water level of the brand mark at rest.
    static let restLevel = 0.52

    static var waterRadius: CGFloat { outerRadius - stroke - waterGap }
}

/// The ring. Fill it with the even-odd rule.
struct EbbRing: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / EbbMarkGeometry.grid
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = EbbMarkGeometry.outerRadius * scale
        let inner = (EbbMarkGeometry.outerRadius - EbbMarkGeometry.stroke) * scale
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
        path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
        return path
    }
}

/// The water: the part of the inner disc below a one-period sine surface. Expects y to grow downward.
struct EbbWater: Shape {
    /// The share still free, 0...1.
    var level: Double

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / EbbMarkGeometry.grid
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = EbbMarkGeometry.waterRadius * scale
        let level = min(max(level, 0), 1)
        if level >= 0.995 { return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)) }
        if level <= 0.004 { return Path() }

        let amplitude = EbbMarkGeometry.amplitude * scale * CGFloat(min(1, level * 3.2, (1 - level) * 3.2))
        let base = center.y + radius - 2 * radius * CGFloat(level)
        let left = center.x - radius
        func surface(_ x: CGFloat) -> CGFloat { base - amplitude * sin(2 * .pi * (x - left) / (2 * radius)) }
        func point(_ angle: CGFloat) -> CGPoint { CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)) }
        func isWet(_ angle: CGFloat) -> Bool {
            let point = point(angle)
            return point.y > surface(point.x)
        }

        // Walk the circle (y grows downward, so a growing angle turns clockwise on screen)
        // and find where it dives under the surface and where it comes back out.
        let steps = 1440
        let step = 2 * CGFloat.pi / CGFloat(steps)
        var entry: Int?
        var exit: Int?
        for index in 0..<steps {
            let now = isWet(CGFloat(index) * step)
            let next = isWet(CGFloat(index + 1) * step)
            if !now && next { entry = index }
            if now && !next { exit = index }
        }
        guard let entry, let exit else { return Path() }
        func refine(_ index: Int) -> CGFloat {
            var low = CGFloat(index) * step
            var high = low + step
            let start = isWet(low)
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if isWet(middle) == start { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
        let start = refine(entry)
        var end = refine(exit)
        if end < start { end += 2 * .pi }

        var path = Path()
        path.move(to: point(start))
        path.addArc(center: center, radius: radius, startAngle: .radians(Double(start)), endAngle: .radians(Double(end)), clockwise: false)
        let from = point(end).x
        let to = point(start).x
        let samples = 28
        for index in 1..<samples {
            let x = from + (to - from) * CGFloat(index) / CGFloat(samples)
            path.addLine(to: CGPoint(x: x, y: surface(x)))
        }
        path.closeSubpath()
        return path
    }
}

/// The mark at rest, for the popover header: the ring in the text colour, the water in the
/// app icon's blue.
struct EbbMark: View {
    private static let water = Color(red: 0.14, green: 0.59, blue: 0.80)

    var body: some View {
        ZStack {
            EbbRing().fill(.primary, style: FillStyle(eoFill: true))
            EbbWater(level: EbbMarkGeometry.restLevel).fill(Self.water)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
