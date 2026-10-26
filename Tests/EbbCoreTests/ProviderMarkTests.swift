import CoreGraphics
import Testing
@testable import EbbCore

@Suite struct ProviderMarkTests {
    @Test func everyPooledProviderHasALogoOrALetterTile() {
        for provider in Providers.all {
            #expect(ProviderMark.forProvider(named: provider.proxyName) != nil, "\(provider.proxyName)")
        }
    }

    @Test func providersWithASimpleIconsLogoUseIt() {
        #expect(ProviderMark.forProvider(named: "claude") == .logo(.claude))
        #expect(ProviderMark.forProvider(named: "Kimi") == .logo(.kimi))
        #expect(ProviderMark.forProvider(named: "codex") == .letters("Cx"))
    }

    @Test func everyLogoParsesInsideItsBox() throws {
        for icon in SimpleIcon.all {
            let path = try #require(SVGPath.cgPath(icon.pathData), "\(icon.slug)")
            let box = path.boundingBoxOfPath
            #expect(box.width > 12 || box.height > 12, "\(icon.slug) \(box)")
            #expect(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 24.01 && box.maxY <= 24.01, "\(icon.slug) \(box)")
        }
    }

    @Test func unknownProvidersGetTheirFirstTwoLetters() {
        #expect(ProviderMark.forProvider(named: "openrouter") == nil)
        #expect(ProviderMark.letters(forName: "openrouter") == "Op")
        #expect(ProviderMark.letters(forName: "my-proxy") == "My")
    }
}

@Suite struct SVGPathTests {
    @Test func readsRelativeCommandsAndPackedNumbers() throws {
        // A 2 × 2 square drawn with relative moves, then a curve whose numbers run together.
        let square = try #require(SVGPath.cgPath("m1 1h2v2h-2z"))
        #expect(square.boundingBoxOfPath == CGRect(x: 1, y: 1, width: 2, height: 2))
        let curve = try #require(SVGPath.cgPath("M0 0C.5-1 1.5-1 2 0"))
        #expect(curve.currentPoint == CGPoint(x: 2, y: 0))
    }

    @Test func readsQuadraticCurvesControlPointFirst() throws {
        let curve = try #require(SVGPath.cgPath("M0 0Q10 10 20 0"))
        #expect(curve.currentPoint == CGPoint(x: 20, y: 0))
        // The curve peaks halfway to its control point.
        #expect(abs(curve.boundingBoxOfPath.maxY - 5) < 0.01)
    }

    @Test func rejectsCommandsItCantDraw() {
        #expect(SVGPath.cgPath("M0 0A5 5 0 0 1 10 10") == nil)
    }

    @Test func rejectsNumbersAfterACloseWithoutACommand() {
        #expect(SVGPath.cgPath("M0 0L1 1Z 2 2") == nil)
    }
}
