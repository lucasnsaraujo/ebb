import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
private let english = Locale(identifier: "en_US")
private let brazil = Locale(identifier: "pt_BR")

private func pool(session: Int, weekly: Int, sessionRefillIn minutes: Double = 130, accounts: [Bool] = [true, true, true, false], readMinutesAgo: Double = 1) -> MenuBarPool {
    MenuBarPool(
        session: WindowReading(window: .session, percent: session, refillsAt: now + minutes * 60),
        weekly: WindowReading(window: .weekly, percent: weekly, refillsAt: now + 3 * 86400),
        accounts: accounts,
        lastReadAt: now - readMinutesAgo * 60
    )
}

private func label(_ style: MenuBarStyle, _ limit: MenuBarLimit = .fiveHour, _ pool: MenuBarPool?, locale: Locale) -> String {
    MenuBarItem(style: style, limit: limit, pool: pool, now: now, locale: locale).accessibilityLabel
}

@Suite struct MenuBarAccessibilityLabelTests {
    @Test func theItemReadsTheWindowTheLimitPicks() {
        let reading = pool(session: 88, weekly: 45)
        #expect(label(.standard, .fiveHour, reading, locale: english) == "Ebb, 5-hour, 88 percent free")
        #expect(label(.standard, .weekly, reading, locale: english) == "Ebb, weekly, 45 percent free")
        #expect(label(.standard, .tighter, reading, locale: english) == "Ebb, weekly, 45 percent free")
        #expect(label(.standard, .fiveHour, reading, locale: brazil) == "Ebb, 5 horas, 88 por cento livre")
        #expect(label(.standard, .weekly, reading, locale: brazil) == "Ebb, semanal, 45 por cento livre")
    }

    @Test func twoWindowStylesReadBothWindows() {
        let reading = pool(session: 88, weekly: 45)
        #expect(label(.both, .weekly, reading, locale: english) == "Ebb, 5-hour, 88 percent free, weekly, 45 percent free")
        #expect(label(.stacked, .fiveHour, reading, locale: brazil) == "Ebb, 5 horas, 88 por cento livre, semanal, 45 por cento livre")
    }

    @Test func theRingCountsTheAccountsReady() {
        #expect(label(.ring, .fiveHour, pool(session: 88, weekly: 45), locale: english) == "Ebb, 5-hour, 88 percent free, weekly, 45 percent free, 3 of 4 accounts ready")
        #expect(label(.ring, .fiveHour, pool(session: 88, weekly: 45), locale: brazil) == "Ebb, 5 horas, 88 por cento livre, semanal, 45 por cento livre, 3 de 4 contas prontas")
        #expect(label(.ring, .fiveHour, pool(session: 88, weekly: 45, accounts: [true]), locale: english) == "Ebb, 5-hour, 88 percent free, weekly, 45 percent free")
    }

    @Test func anEmptyWindowAndTheRefillStyleSayWhenMoreComes() {
        #expect(label(.standard, .fiveHour, pool(session: 0, weekly: 45, sessionRefillIn: 100), locale: english) == "Ebb, 5-hour, 0 percent free, more in 1h 40m")
        #expect(label(.refillTime, .fiveHour, pool(session: 88, weekly: 45), locale: english) == "Ebb, 5-hour, 88 percent free, more in 2h 10m")
        #expect(label(.refillTime, .fiveHour, pool(session: 88, weekly: 45), locale: brazil) == "Ebb, 5 horas, 88 por cento livre, mais em 2h 10min")
    }

    @Test func oldAndMissingReadingsSaySo() {
        #expect(label(.standard, .fiveHour, pool(session: 88, weekly: 45, readMinutesAgo: 11), locale: english) == "Ebb, 5-hour, 88 percent free, not updated recently")
        #expect(label(.standard, .fiveHour, pool(session: 88, weekly: 45, readMinutesAgo: 11), locale: brazil) == "Ebb, 5 horas, 88 por cento livre, sem atualização recente")
        #expect(label(.standard, .fiveHour, nil, locale: english) == "Ebb, no reading")
        #expect(label(.standard, .fiveHour, nil, locale: brazil) == "Ebb, sem leitura")
    }

    @Test func devinsDailyWindowIsSpokenAsDaily() {
        let reading = MenuBarPool(
            session: WindowReading(window: .session, percent: 73, refillsAt: nil, shortWindow: .day),
            weekly: WindowReading(window: .weekly, percent: 40, refillsAt: nil, shortWindow: .day),
            accounts: [true], lastReadAt: now
        )
        #expect(label(.standard, .fiveHour, reading, locale: english) == "Ebb, daily, 73 percent free")
        #expect(label(.standard, .fiveHour, reading, locale: brazil) == "Ebb, diário, 73 por cento livre")
    }
}

@Suite struct MeterAccessibilityTests {
    @Test func aPoolMeterSaysWhatIsFreeAndWhatComesBack() {
        #expect(AccessibilityText.meter(freePercent: 88, comingBackPercent: 0, locale: english) == "88 percent free")
        #expect(AccessibilityText.meter(freePercent: 88, comingBackPercent: 5, locale: english) == "88 percent free, 5 percent coming back")
        #expect(AccessibilityText.meter(freePercent: 88, comingBackPercent: 5, locale: brazil) == "88 por cento livre, 5 por cento voltando")
        #expect(AccessibilityText.meter(freePercent: 0, comingBackPercent: 0, locale: brazil) == "0 por cento livre")
    }

    @Test func anAccountMeterSaysWhatIsFreeOrWhyThereIsNoBar() {
        #expect(AccessibilityText.miniMeter(freePercent: 36, isUncapped: false, locale: english) == "36 percent free")
        #expect(AccessibilityText.miniMeter(freePercent: nil, isUncapped: true, locale: english) == "no weekly limit")
        #expect(AccessibilityText.miniMeter(freePercent: nil, isUncapped: false, locale: english) == "no reading")
        #expect(AccessibilityText.miniMeter(freePercent: 36, isUncapped: false, locale: brazil) == "36 por cento livre")
        #expect(AccessibilityText.miniMeter(freePercent: nil, isUncapped: true, locale: brazil) == "sem limite semanal")
        #expect(AccessibilityText.miniMeter(freePercent: nil, isUncapped: false, locale: brazil) == "sem leitura")
    }

    @Test func anAccountRowReadsNamePlanStatusBothWindowsAndShare() {
        let row = AccessibilityText.accountRow(
            name: "work", plan: "Max 20x", status: "Counted in the pool", short: .fiveHours,
            sessionFree: 36, weeklyFree: 29, hasNoWeeklyCap: false, share: 18, locale: english
        )
        #expect(row == "work, Max 20x, Counted in the pool, 5-hour: 36 percent free, Weekly: 29 percent free, share 18 percent")
        let uncapped = AccessibilityText.accountRow(
            name: "research", plan: nil, status: "Contada na cota", short: .fiveHours,
            sessionFree: 88, weeklyFree: nil, hasNoWeeklyCap: true, share: nil, locale: brazil
        )
        #expect(uncapped == "research, Contada na cota, 5 horas: 88 por cento livre, Semanal: sem limite semanal, sem parcela")
        let daily = AccessibilityText.accountRow(
            name: "dev", plan: "Pro", status: "Counted in the pool", short: .day,
            sessionFree: 73, weeklyFree: 40, hasNoWeeklyCap: false, share: 100, locale: english
        )
        #expect(daily == "dev, Pro, Counted in the pool, Daily: 73 percent free, Weekly: 40 percent free, share 100 percent")
    }
}
