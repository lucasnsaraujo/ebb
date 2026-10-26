import EbbCore
import SwiftUI

/// Claude mark plus the 5-hour window's free share, like the Battery item: "5h 89%".
/// The mark gets an orange dot when the weekly window is nearly gone.
struct MenuBarLabel: View {
    let summary: PoolSummary?

    private static let mark = ClaudeMark.templateImage(pointSize: 15)
    private static let badgedMark = ClaudeMark.badgedImage(pointSize: 15)

    var body: some View {
        if let reading = LaunchOptions.demo == .low ? MenuBarReading(sessionPercent: 8, isWeeklyLow: true) : summary.map(MenuBarReading.init) {
            let level = PoolLevel(Double(reading.sessionPercent))
            HStack(spacing: 4) {
                Image(nsImage: reading.isWeeklyLow ? Self.badgedMark : Self.mark)
                Text("5h \(level.percent)%")
                    .foregroundStyle(level.warningTint ?? .primary)
            }
            .accessibilityLabel("Ebb, 5-hour \(level.percent) percent free\(reading.isWeeklyLow ? ", weekly nearly used up" : "")")
        } else {
            Image(nsImage: Self.mark)
                .accessibilityLabel("Ebb, no reading")
        }
    }
}
