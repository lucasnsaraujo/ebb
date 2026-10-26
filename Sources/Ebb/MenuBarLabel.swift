import EbbCore
import SwiftUI

/// The provider's mark plus its short window's free share, like the Battery item: "5h 89%".
/// The mark gets an orange dot when the weekly window is nearly gone.
struct MenuBarLabel: View {
    let summary: PoolSummary?
    /// `nil` or Claude shows the Claude mark.
    var provider: String?

    private static let mark = ClaudeMark.templateImage(pointSize: 15)
    private static let badgedMark = ClaudeMark.badgedImage(pointSize: 15)

    var body: some View {
        let short = ProviderDisplay.shortWindow(provider)
        if let reading = LaunchOptions.demo == .low ? MenuBarReading(sessionPercent: 8, isWeeklyLow: true) : summary.map(MenuBarReading.init) {
            let level = PoolLevel(Double(reading.sessionPercent))
            HStack(spacing: 4) {
                mark(isBadged: reading.isWeeklyLow)
                Text("\(short.abbreviation) \(level.percent)%")
                    .foregroundStyle(level.warningTint ?? .primary)
            }
            .accessibilityLabel("Ebb, \(providerName)\(short.title) \(level.percent) percent free\(reading.isWeeklyLow ? ", weekly nearly used up" : "")")
        } else {
            mark(isBadged: false)
                .accessibilityLabel("Ebb, no reading")
        }
    }

    private var providerName: String {
        ProviderDisplay.isClaude(provider) ? "" : "\(ProviderDisplay.title(provider ?? "")), "
    }

    @ViewBuilder
    private func mark(isBadged: Bool) -> some View {
        if ProviderDisplay.isClaude(provider) {
            Image(nsImage: isBadged ? Self.badgedMark : Self.mark)
        } else {
            Image(systemName: ProviderDisplay.symbol(provider ?? ""))
                .overlay(alignment: .topTrailing) {
                    if isBadged {
                        Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 2, y: -2)
                    }
                }
        }
    }
}
