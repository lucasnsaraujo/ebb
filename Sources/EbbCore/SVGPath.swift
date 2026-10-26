import CoreGraphics

/// Turns SVG path data into a `CGPath`, in the path's own units.
/// Reads M, L, H, V, C, Q and Z, absolute or relative; arcs and shorthand curves aren't supported.
public enum SVGPath {
    public static func cgPath(_ data: String) -> CGPath? {
        let path = CGMutablePath()
        let scanner = Scanner(data)
        var current = CGPoint.zero
        var command: Character = "M"
        while let next = scanner.nextCommand(default: command) {
            command = next
            let origin = command.isLowercase ? current : .zero
            switch command.uppercased() {
            case "M":
                guard let point = scanner.point(offsetBy: origin) else { return nil }
                current = point
                path.move(to: current)
                // Coordinates after a move are line-tos.
                command = command.isLowercase ? "l" : "L"
            case "L":
                guard let point = scanner.point(offsetBy: origin) else { return nil }
                current = point
                path.addLine(to: current)
            case "H":
                guard let x = scanner.number() else { return nil }
                current.x = x + origin.x
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return nil }
                current.y = y + origin.y
                path.addLine(to: current)
            case "C":
                guard let control1 = scanner.point(offsetBy: origin),
                      let control2 = scanner.point(offsetBy: origin),
                      let end = scanner.point(offsetBy: origin)
                else { return nil }
                current = end
                path.addCurve(to: end, control1: control1, control2: control2)
            case "Q":
                guard let control = scanner.point(offsetBy: origin), let end = scanner.point(offsetBy: origin) else { return nil }
                current = end
                path.addQuadCurve(to: end, control: control)
            case "Z":
                path.closeSubpath()
                current = path.currentPoint
                // Nothing may follow a close without a new command letter.
                command = "?"
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Reads command letters and numbers like `-.2307` or `.079-.2307`.
    private final class Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) {
            characters = Array(text)
        }

        /// The next command letter, or `previous` when more coordinates follow without one.
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

        func point(offsetBy origin: CGPoint) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: origin.x + x, y: origin.y + y)
        }

        func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var hasDot = false
            var hasExponent = false
            while index < characters.count {
                let character = characters[index]
                if character == "-" || character == "+" {
                    guard text.isEmpty || text.last == "e" else { break }
                } else if character == "." {
                    guard !hasDot, !hasExponent else { break }
                    hasDot = true
                } else if character == "e", !hasExponent, !text.isEmpty {
                    hasExponent = true
                } else if !character.isNumber {
                    break
                }
                text.append(character)
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }

        private func skipSeparators() {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
        }
    }
}
