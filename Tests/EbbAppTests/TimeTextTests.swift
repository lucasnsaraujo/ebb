import EbbCore
import Foundation
import Testing
@testable import Ebb

private let now = ISO8601DateFormatter().date(from: "2026-10-26T23:50:00Z")!
private let utc = TimeZone(identifier: "UTC")!
private let english = Locale(identifier: "en_US")
private let brazil = Locale(identifier: "pt_BR")

/// The relative times under the meters and in the hover card. Beyond an hour they turn into a
/// clock time, which must read as one in both locales: "1:25 AM", never a bare "1:25".
@Suite struct TimeTextTests {
    @Test func withinAnHourTheTimeIsRelative() {
        #expect(TimeText.soon(now + 41 * 60, now: now, locale: english, timeZone: utc).hasSuffix("41 min"))
        #expect(TimeText.soon(now + 41 * 60, now: now, locale: brazil, timeZone: utc).hasSuffix("41 min"))
    }

    @Test func beyondAnHourTheClockKeepsItsZeroOrItsDayPeriod() {
        #expect(TimeText.soon(now + 95 * 60, now: now, locale: english, timeZone: utc) == "1:25\u{202F}AM")
        #expect(TimeText.soon(now + 95 * 60, now: now, locale: brazil, timeZone: utc) == "01:25")
        #expect(TimeText.later(now + 13 * 3600, now: now, locale: english, timeZone: utc) == "Tue 12:50\u{202F}PM")
        #expect(TimeText.later(now + 13 * 3600, now: now, locale: brazil, timeZone: utc) == "ter. 12:50")
    }
}
