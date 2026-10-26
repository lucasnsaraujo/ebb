import AppKit
import SwiftUI

/// The Claude spark, from Simple Icons (`icons/claude.svg`, 24×24 view box).
struct ClaudeMark: Shape {
    private static let viewBox: CGFloat = 24
    private static let pathData = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    /// Parsed once; the source only uses M, L, H, V, C and Z.
    private static let viewBoxPath: Path = {
        let path = CGMutablePath()
        let scanner = SVGPathScanner(pathData)
        var current = CGPoint.zero
        var command: Character = "M"
        while let next = scanner.nextCommand(default: command) {
            command = next
            let isRelative = command.isLowercase
            let origin = isRelative ? current : .zero
            switch command.uppercased() {
            case "M":
                current = scanner.point(offsetBy: origin)
                path.move(to: current)
                command = isRelative ? "l" : "L"
            case "L":
                current = scanner.point(offsetBy: origin)
                path.addLine(to: current)
            case "H":
                current.x = scanner.number() + (isRelative ? current.x : 0)
                path.addLine(to: current)
            case "V":
                current.y = scanner.number() + (isRelative ? current.y : 0)
                path.addLine(to: current)
            case "C":
                let control1 = scanner.point(offsetBy: origin)
                let control2 = scanner.point(offsetBy: origin)
                current = scanner.point(offsetBy: origin)
                path.addCurve(to: current, control1: control1, control2: control2)
            case "Z":
                path.closeSubpath()
                current = path.currentPoint
            default:
                assertionFailure("Unsupported SVG command \(command)")
                return Path(path)
            }
        }
        return Path(path)
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.viewBox
        let transform = CGAffineTransform(translationX: rect.midX - Self.viewBox * scale / 2, y: rect.midY - Self.viewBox * scale / 2)
            .scaledBy(x: scale, y: scale)
        return Self.viewBoxPath.applying(transform)
    }

    /// The mark with an orange dot set into its top-right corner. Not a template, so the
    /// dot keeps its color; the mark is drawn in the label color of whatever appearance
    /// it's drawn in, so it still matches the menu bar.
    static func badgedImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(cgPath: ClaudeMark().path(in: rect).cgPath).fill()
            let dot = NSRect(x: rect.maxX - 6, y: rect.minY, width: 6, height: 6)
            // A clear ring around the dot separates it from the mark.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.accessibilityDescription = "Ebb, weekly nearly used up"
        return image
    }

    /// A template image, so the menu bar tints it like system items.
    static func templateImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(ClaudeMark().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ebb"
        return image
    }
}

/// Reads SVG path data: command letters and numbers like `-.2307` or `.079-.2307`.
private final class SVGPathScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    func nextCommand(default previous: Character) -> Character? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let character = characters[index]
        if character.isLetter {
            index += 1
            return character
        }
        return previous
    }

    func point(offsetBy origin: CGPoint) -> CGPoint {
        let x = number()
        let y = number()
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }

    func number() -> CGFloat {
        skipSeparators()
        var text = ""
        var hasDot = false
        while index < characters.count {
            let character = characters[index]
            if character == "-" || character == "+" {
                guard text.isEmpty else { break }
            } else if character == "." {
                guard !hasDot else { break }
                hasDot = true
            } else if !character.isNumber {
                break
            }
            text.append(character)
            index += 1
        }
        return CGFloat(Double(text) ?? 0)
    }

    private func skipSeparators() {
        while index < characters.count, characters[index] == " " || characters[index] == "," {
            index += 1
        }
    }
}
