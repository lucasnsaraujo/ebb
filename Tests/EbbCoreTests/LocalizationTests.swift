import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
private let english = Locale(identifier: "en_US")
private let brazil = Locale(identifier: "pt_BR")
private let utc = TimeZone(identifier: "UTC")!

private func summary(read: Int, weeklyLimited: Int = 0, unread: Int = 0) -> PoolSummary {
    PoolSummary(
        session: WindowSummary(freePercent: 50, resets: []),
        weekly: WindowSummary(freePercent: 50, resets: []),
        isPartial: unread > 0, totalWeight: PlanWeight(Double(read)), readAccounts: read, unreadAccounts: unread, weeklyLimitedAccounts: weeklyLimited
    )
}

@Suite struct PluralTests {
    @Test func accountsAtTheirWeeklyLimitAgreeInBothLanguages() {
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 1), window: .session, now: now, locale: english) == ["1 of 4 accounts at their weekly limit"])
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 2), window: .session, now: now, locale: english) == ["2 of 4 accounts at their weekly limit"])
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 1), window: .session, now: now, locale: brazil) == ["1 de 4 contas está no limite semanal"])
        #expect(PoolNotes.lines(summary(read: 4, weeklyLimited: 2), window: .session, now: now, locale: brazil) == ["2 de 4 contas estão no limite semanal"])
        #expect(PoolNotes.lines(summary(read: 1, weeklyLimited: 1), window: .session, now: now, locale: brazil) == ["A única conta está no limite semanal"])
    }

    @Test func unreadAccountsCountInBothLanguages() {
        #expect(PoolNotes.lines(summary(read: 3, unread: 1), window: .weekly, now: now, locale: english) == ["1 account can't be read right now"])
        #expect(PoolNotes.lines(summary(read: 3, unread: 2), window: .weekly, now: now, locale: english) == ["2 accounts can't be read right now"])
        #expect(PoolNotes.lines(summary(read: 3, unread: 1), window: .weekly, now: now, locale: brazil) == ["1 conta não pode ser lida agora"])
        #expect(PoolNotes.lines(summary(read: 3, unread: 2), window: .weekly, now: now, locale: brazil) == ["2 contas não podem ser lidas agora"])
    }

    @Test func heldAccountsCountInBothLanguages() {
        #expect(StuckCooldown.line(count: 1, locale: english) == "CLIProxyAPI is still holding 1 account in cooldown.")
        #expect(StuckCooldown.line(count: 3, locale: english) == "CLIProxyAPI is still holding 3 accounts in cooldown.")
        #expect(StuckCooldown.line(count: 1, locale: brazil) == "O CLIProxyAPI ainda mantém 1 conta em espera.")
        #expect(StuckCooldown.line(count: 3, locale: brazil) == "O CLIProxyAPI ainda mantém 3 contas em espera.")
    }

    @Test func theLastDaysOfPaceCountInBothLanguages() {
        let oneDay = Pace.Forecast(outlook: .lasts, basis: 86400)
        let fiveDays = Pace.Forecast(outlook: .lasts, basis: 5 * 86400)
        #expect(PaceText.basis(oneDay, window: .weekly, locale: english) == "Based on the last day")
        #expect(PaceText.basis(fiveDays, window: .weekly, locale: english) == "Based on the last 5 days")
        #expect(PaceText.basis(oneDay, window: .weekly, locale: brazil) == "Com base no último dia")
        #expect(PaceText.basis(fiveDays, window: .weekly, locale: brazil) == "Com base nos últimos 5 dias")
    }
}

@Suite struct DurationTextTests {
    @Test func paceDurationsReadInBothLanguages() {
        #expect(PaceText.duration(130 * 60, locale: english) == "2 h 10 min")
        #expect(PaceText.duration(130 * 60, locale: brazil) == "2 h 10 min")
        #expect(PaceText.duration(9 * 60, locale: english) == "Under 10 min")
        #expect(PaceText.duration(9 * 60, locale: brazil) == "Menos de 10 min")
        #expect(PaceText.duration(120 * 60, locale: brazil) == "2 h")
        #expect(PaceText.duration(37 * 60, locale: brazil) == "35 min")
    }

    @Test func runOutLinesReadInBothLanguages() {
        let single = Pace.Forecast(outlook: .runsOut(in: 130 * 60), basis: 45 * 60)
        let soon = Pace.Forecast(outlook: .runsOut(in: 5 * 60), basis: 45 * 60)
        let range = Pace.Forecast(outlook: .runsOut(in: 80 * 60, within: (60 * 60)...(110 * 60)), basis: 45 * 60)
        #expect(PaceText.inline(single, window: .session, now: now, locale: english) == "About 2 h 10 min left")
        #expect(PaceText.sentence(single, window: .session, short: .fiveHours, now: now, locale: english) == "About 2 h 10 min left at this pace")
        #expect(PaceText.sentence(single, window: .session, short: .fiveHours, now: now, locale: brazil) == "Cerca de 2 h 10 min restantes neste ritmo")
        // The line under the meter has 124 pt; "Cerca de 2 h 10 min restantes" needs 171.
        #expect(PaceText.inline(single, window: .session, now: now, locale: brazil) == "Restam ~2 h 10 min")
        #expect(PaceText.inline(soon, window: .session, now: now, locale: brazil) == "Restam < 10 min")
        #expect(PaceText.inline(range, window: .session, now: now, locale: brazil) == "Restam ~1 h 30 min")
        #expect(PaceText.sentence(range, window: .session, short: .fiveHours, now: now, locale: brazil) == "Cerca de 1 h 30 min restantes neste ritmo")
        #expect(PaceText.basis(single, window: .session, locale: brazil) == "Com base em 45 min de atividade")
    }

    @Test func weeklyPaceUsesTheLocalesDayAndTime() {
        let forecast = Pace.Forecast(outlook: .runsOut(in: 3.6 * 86400), basis: 5 * 86400)
        #expect(PaceText.inline(forecast, window: .weekly, now: now, timeZone: utc, locale: english) == "Runs out ~Fri 10:00\u{202F}AM")
        #expect(PaceText.inline(forecast, window: .weekly, now: now, timeZone: utc, locale: brazil) == "Acaba ~sex. 10:00")
        #expect(PaceText.sentence(forecast, window: .weekly, short: .fiveHours, now: now, timeZone: utc, locale: brazil) == "Acaba por volta de sex. 10:00 neste ritmo")
        #expect(PaceText.sentence(Pace.Forecast(outlook: .lasts, basis: 5 * 86400), window: .weekly, short: .fiveHours, now: now, locale: brazil) == "Dura até a renovação neste ritmo")
        #expect(PaceText.sentence(Pace.Forecast(outlook: .lasts, basis: 45 * 60), window: .session, short: .day, now: now, locale: brazil) == "Dura pelas próximas 24 horas neste ritmo")
    }

    @Test func refillTimesInTheMenuBarUseTheLocalesUnits() {
        #expect(RefillText.until(now + 37.2 * 60, now: now, locale: english) == "38m")
        #expect(RefillText.until(now + 130 * 60, now: now, locale: english) == "2h 10m")
        #expect(RefillText.until(now + 37.2 * 60, now: now, locale: brazil) == "38min")
        #expect(RefillText.until(now + 130 * 60, now: now, locale: brazil) == "2h 10min")
        #expect(RefillText.until(now + 60 * 60, now: now, locale: brazil) == "1h")
        #expect(RefillText.until(now + (3 * 24 + 3.5) * 3600, now: now, locale: brazil) == "3d 4h")
        #expect(RefillText.until(now + 2 * 24 * 3600, now: now, locale: brazil) == "2d")
    }

    @Test func theLockedExplanationReadsInBothLanguages() {
        var locked = summary(read: 4)
        locked.session.lockedPercent = 57
        #expect(PoolNotes.lines(locked, window: .session, now: now, locale: english) == ["Locked: accounts that used up their week"])
        #expect(PoolNotes.lines(locked, window: .session, now: now, locale: brazil) == ["Bloqueado: contas sem semanal"])
    }

    @Test func readingAgesReadInBothLanguages() {
        #expect(PoolNotes.lines(summary(read: 3), window: .weekly, now: now, locale: english).isEmpty)
        var fresh = summary(read: 3)
        fresh.oldestReadingAt = now - 12
        #expect(PoolNotes.lines(fresh, window: .weekly, now: now, locale: english).isEmpty)
        #expect(PoolNotes.lines(fresh, window: .weekly, now: now, locale: brazil).isEmpty)
        fresh.oldestReadingAt = now - 3 * 60
        #expect(PoolNotes.lines(fresh, window: .weekly, now: now, locale: brazil).isEmpty)
        var stale = summary(read: 3)
        stale.oldestReadingAt = now - 11 * 60
        #expect(PoolNotes.lines(stale, window: .weekly, now: now, locale: english) == ["As of 11 min ago"])
        #expect(PoolNotes.lines(stale, window: .weekly, now: now, locale: brazil) == ["Atualizado há 11 min"])
        stale.oldestReadingAt = now - 2 * 3600
        #expect(PoolNotes.lines(stale, window: .weekly, now: now, locale: brazil) == ["Atualizado há 2 h"])
    }
}

@Suite struct AlertTextTests {
    @Test func expiryNudgeMomentsFollowTheLocale() {
        #expect(ExpiryNudge.moment(now + 2 * 3600, now: now, timeZone: utc, locale: english) == "today 9:34\u{202F}PM")
        #expect(ExpiryNudge.moment(now + 2 * 3600, now: now, timeZone: utc, locale: brazil) == "hoje 21:34")
        #expect(ExpiryNudge.moment(now + 20 * 3600, now: now, timeZone: utc, locale: brazil) == "amanhã 15:34")
        #expect(ExpiryNudge.moment(now + 50 * 3600, now: now, timeZone: utc, locale: brazil) == "qua. 21:34")
    }

    @Test func expiryNudgeSpeaksPortuguese() {
        var nudge = ExpiryNudge()
        let accounts = [
            PoolAccount(id: "a", weight: PlanWeight(1), limits: [UsageLimit(kind: .weeklyAll, usedPercent: 20, resetsAt: now + 20 * 3600)], readAt: now),
            PoolAccount(id: "b", weight: PlanWeight(1), limits: [UsageLimit(kind: .weeklyAll, usedPercent: 100, resetsAt: now + 20 * 3600)], readAt: now),
        ]
        let alerts = nudge.alerts(pool: "claude", title: "Claude", accounts: accounts, totalWeight: 2, forecast: nil, now: now, timeZone: utc, locale: brazil)
        #expect(alerts.map(\.title) == ["Claude: 40% da cota desta semana expira sem uso amanhã 15:34"])
        #expect(alerts.map(\.body) == ["Trabalho iniciado antes disso ainda pode usá-la."])
    }

    @Test func incidentsSpeakPortuguese() {
        #expect(ServiceHealth.degradedPerformance.line(title: "Claude", locale: brazil) == "Claude: desempenho degradado")
        #expect(ServiceHealth.majorOutage.line(title: "Codex", locale: brazil) == "Codex: interrupção total")
        var tracker = IncidentTracker()
        let alerts = tracker.alerts(provider: "claude", title: "Claude", health: .partialOutage, now: now, locale: brazil)
        #expect(alerts.map(\.title) == ["Claude: interrupção parcial"])
        #expect(alerts.map(\.body) == ["Informado em status.claude.com. As sessões podem falhar ou ficar lentas até ser resolvido."])
    }

    @Test func extraUsageSpeaksPortugueseWithLocalNumbers() {
        #expect(ExtraUsage.claudeOverage(isNearLimit: true).text(locale: brazil) == "Uso extra ativado, perto do limite")
        #expect(ExtraUsage.codexCredits(balance: 12.5).text(locale: brazil) == "Créditos: 12,5")
        #expect(ExtraUsage.codexCredits(balance: 12.5).text(locale: english) == "Credits: 12.5")
    }

    @Test func theShortcutsSentenceSpeaksPortuguese() throws {
        let claude = ProviderStatus(
            id: "claude", title: "Claude", shortWindow: .fiveHours,
            session: WindowStatus(freePercent: 88.4, resets: [Restoration(date: now + 30 * 60, gain: 12)]),
            weekly: WindowStatus(freePercent: 45, resets: []), isPartial: false, readAt: now
        )
        let status = PoolStatus(updatedAt: now, menuBarProvider: "claude", providers: [claude])
        let answer = try #require(PoolAnswer(status, provider: nil, now: now))
        #expect(answer.sentence(timeZone: utc, locale: english) == "Claude: 88% of the 5-hour pool and 45% of the weekly pool are free. Next refill: +12% of the 5-hour pool at 8:04\u{202F}PM.")
        #expect(answer.sentence(timeZone: utc, locale: brazil) == "Claude: 88% da cota de 5 horas e 45% da cota semanal estão livres. Próxima renovação: +12% da cota de 5 horas às 20:04.")
    }
}

@Suite struct CatalogTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalogs = [
        "Sources/EbbCore/Resources/EbbCore.xcstrings",
        "Sources/Ebb/Resources/Localizable.xcstrings",
        "Sources/Ebb/Resources/AppShortcuts.xcstrings",
    ]

    /// Every string in every catalog has a Brazilian Portuguese translation, plural forms included.
    @Test(arguments: catalogs) func everyStringHasBrazilianPortuguese(catalog: String) throws {
        let data = try Data(contentsOf: Self.root.appending(path: catalog))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            let translated = localizations["pt-BR"].map(Self.isTranslated) ?? false
            #expect(translated, "\(catalog): \(key)")
        }
    }

    /// Each pt-BR value carries the same placeholders as its English key, plural forms and
    /// substitutions included, so no format ever gets an argument of the wrong kind.
    @Test(arguments: catalogs) func everyTranslationKeepsTheEnglishPlaceholders(catalog: String) throws {
        let data = try Data(contentsOf: Self.root.appending(path: catalog))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for value in localizations["pt-BR"].map(Self.values) ?? [] {
                #expect(Self.placeholders(in: value) == Self.placeholders(in: key), "\(catalog): \(key) → \(value)")
            }
        }
    }

    /// The texts a localization can show: its one value, or every plural form, with each
    /// `%#@name@` expanded to the substitution's argument and the arguments its forms add.
    private static func values(of localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], var value = unit["value"] as? String {
            for (name, substitution) in localization["substitutions"] as? [String: [String: Any]] ?? [:] {
                let specifier = substitution["formatSpecifier"] as? String ?? "@"
                let inner = (values(of: substitution).first ?? "").replacing("%arg", with: "")
                value = value.replacing("%#@\(name)@", with: "%\(specifier)\(inner)")
            }
            return [value]
        }
        guard let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] else { return [] }
        return plural.values.flatMap(values)
    }

    private static func placeholders(in text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(lld|@|d|f)|\$\{[^}]+\}/).map { $0.1.map(String.init) ?? "parameter" }.sorted()
    }

    private static func isTranslated(_ localization: [String: Any]) -> Bool {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return unit["state"] as? String == "translated" && !(unit["value"] as? String ?? "").isEmpty
        }
        guard let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] else { return false }
        return Set(plural.keys).isSuperset(of: ["one", "other"]) && plural.values.allSatisfy(isTranslated)
    }
}

@Suite struct ClockFormatTests {
    /// 21:34 UTC, the same evening as `now`.
    private let evening = now + 2 * 3600
    private let weeklyRunOut = Pace.Forecast(outlook: .runsOut(in: 7200), basis: 5 * 86400)

    @Test func aTwelveHourLocaleWritesAMOrPM() {
        #expect(ExpiryNudge.moment(evening, now: now, timeZone: utc, locale: english) == "today 9:34\u{202F}PM")
        #expect(StatusReport.moment(evening, now: now, timeZone: utc, locale: english) == "at 9:34\u{202F}PM")
        #expect(PaceText.inline(weeklyRunOut, window: .weekly, now: now, timeZone: utc, locale: english) == "Runs out ~Mon 10:00\u{202F}PM")
    }

    @Test func aSmallHourKeepsItsZeroOrItsDayPeriod() {
        let smallHours = UsageLimit.parseTimestamp("2026-10-27T01:15:00+00:00")!
        #expect(ClockText.time(smallHours, locale: english, timeZone: utc) == "1:15\u{202F}AM")
        #expect(ClockText.time(smallHours, locale: brazil, timeZone: utc) == "01:15")
        #expect(ClockText.weekdayAndTime(smallHours, locale: english, timeZone: utc) == "Tue 1:15\u{202F}AM")
        #expect(ClockText.weekdayAndTime(smallHours, locale: brazil, timeZone: utc) == "ter. 01:15")
        #expect(StatusReport.moment(smallHours, now: smallHours - 3600, timeZone: utc, locale: brazil) == "at 01:15")
        #expect(ExpiryNudge.moment(smallHours, now: smallHours - 3600, timeZone: utc, locale: brazil) == "hoje 01:15")
        let runOut = Pace.Forecast(outlook: .runsOut(in: 3600), basis: 5 * 86400)
        #expect(PaceText.inline(runOut, window: .weekly, now: smallHours - 3600, timeZone: utc, locale: brazil) == "Acaba ~ter. 01:00")
    }

    @Test func aTwentyFourHourLocaleWritesNoAMOrPM() {
        let lines = [
            ExpiryNudge.moment(evening, now: now, timeZone: utc, locale: brazil),
            StatusReport.moment(evening, now: now, timeZone: utc, locale: brazil),
            PaceText.inline(weeklyRunOut, window: .weekly, now: now, timeZone: utc, locale: brazil) ?? "",
        ]
        #expect(lines == ["hoje 21:34", "at 21:34", "Acaba ~seg. 22:00"])
        #expect(lines.allSatisfy { !$0.contains("AM") && !$0.contains("PM") })
    }
}

/// Every literal handed to a localizing call in the sources has a catalog entry, so no string
/// shows in English for want of one. Literals returned bare from a `switch` aren't seen.
@Suite struct CatalogCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Calls whose first string literal is a key: SwiftUI's, App Intents' and `String(localized:)`
    /// in the app, `Localization.text` in EbbCore. A ternary condition may sit before the literal.
    private static let targets = [
        (
            "Sources/Ebb", "Sources/Ebb/Resources/Localizable.xcstrings",
            #"(?:\b(?:Text|Button|Label|Section|Toggle|Picker|LabeledContent|TextField|SecureField|Link|IntentDescription|Summary|LocalizedStringResource)\(|\.(?:help|accessibilityLabel|accessibilityValue|accessibilityHint)\(|String\(localized:|\b(?:title|description|shortTitle):|(?:LocalizedStringResource|TypeDisplayRepresentation)\s*=)"#
        ),
        ("Sources/EbbCore", "Sources/EbbCore/Resources/EbbCore.xcstrings", #"Localization\.text\("#),
    ]

    @Test(arguments: targets) func everyLocalizedLiteralIsInTheCatalog(folder: String, catalog: String, prefixes: String) throws {
        let calls = try Regex(prefixes + #"(?:[^"\n]*?\?)?\s*(?=")"#)
        let data = try Data(contentsOf: Self.root.appending(path: catalog))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(try #require(json["strings"] as? [String: Any]).keys.map(Self.normalizedKey))
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.root.appending(path: folder).path).filter { $0.hasSuffix(".swift") }
        var seen = 0
        for file in files {
            let source = try String(contentsOf: Self.root.appending(path: "\(folder)/\(file)"), encoding: .utf8)
            for literal in Self.literals(in: source, after: calls) {
                seen += 1
                #expect(keys.contains(Self.normalizedLiteral(literal)), "\(file): \"\(literal)\"")
            }
        }
        #expect(seen > 50)
    }

    /// Format specifiers and `${parameter}` placeholders become `%?`.
    private static func normalizedKey(_ key: String) -> String {
        key.replacing(/%\d*\$?(?:lld|@|d|f)|\$\{[^}]*\}/, with: "%?")
    }

    /// Interpolations become `%?`; with any, a bare `%` becomes the `%%` its key carries, since only
    /// an interpolated literal is a format string.
    private static func normalizedLiteral(_ text: String) -> String {
        guard text.contains("\\(") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "\\(") {
            result += rest[..<open.lowerBound].replacing("%", with: "%%")
            var depth = 1
            var index = open.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            result += "%?"
            rest = rest[index...]
        }
        return result + rest.replacing("%", with: "%%")
    }

    /// The literal after each localizing call, and a ternary's second one: `? "a" : "b"`.
    private static func literals(in source: String, after calls: Regex<AnyRegexOutput>) -> [String] {
        var found: [String] = []
        for match in source.matches(of: calls) {
            guard let first = literal(in: source, from: match.range.upperBound) else { continue }
            found.append(first.text)
            let after = source[first.end...].drop(while: \.isWhitespace)
            guard after.first == ":" else { continue }
            let next = after.dropFirst().drop(while: \.isWhitespace)
            if let second = literal(in: source, from: next.startIndex) { found.append(second.text) }
        }
        return found
    }

    /// Reads a Swift string literal starting at `start`, minding `\(…)` that may hold quotes of its own.
    private static func literal(in source: String, from start: String.Index) -> (text: String, end: String.Index)? {
        guard start < source.endIndex, source[start] == "\"" else { return nil }
        var index = source.index(after: start)
        var depth = 0
        while index < source.endIndex {
            let character = source[index]
            if depth > 0 {
                if character == "\"", let nested = literal(in: source, from: index) {
                    index = nested.end
                    continue
                }
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            } else if character == "\\" {
                let following = source.index(after: index)
                if following < source.endIndex, source[following] == "(" { depth = 1 }
                index = source.index(following, offsetBy: 1, limitedBy: source.endIndex) ?? source.endIndex
                continue
            } else if character == "\"" {
                return (String(source[source.index(after: start)..<index]), source.index(after: index))
            }
            index = source.index(after: index)
        }
        return nil
    }
}

/// Which of the shipped languages a user's list gets, by BCP 47 tag. One Portuguese ships, so
/// every Portuguese reads it; a language not shipped reads the development one, English.
@Suite struct LanguageChoiceTests {
    private let shipped = ["en", "pt-BR"]

    @Test func brazilianPortugueseReadsPortuguese() {
        #expect(Localization.language(for: ["pt-BR"], among: shipped) == "pt-BR")
    }

    @Test func plainPortugueseReadsPortuguese() {
        #expect(Localization.language(for: ["pt"], among: shipped) == "pt-BR")
    }

    @Test func europeanPortugueseReadsTheOnePortugueseShipped() {
        #expect(Localization.language(for: ["pt-PT"], among: shipped) == "pt-BR")
    }

    @Test func frenchReadsEnglish() {
        #expect(Localization.language(for: ["fr"], among: shipped) == nil)
    }

    @Test func theFirstPreferenceWithAMatchWins() {
        #expect(Localization.language(for: ["fr", "pt-PT", "en"], among: shipped) == "pt-BR")
        #expect(Localization.language(for: ["en-GB", "pt-BR"], among: shipped) == "en")
    }

    @Test func underscoresAndCaseDoNotMatter() {
        #expect(Localization.language(for: ["PT_br"], among: shipped) == "pt-BR")
        #expect(Localization.language(for: ["en_US"], among: shipped) == "en")
    }

    /// The app's own strings go through Bundle.main, whose folder choice must agree.
    @Test func theMainBundleWouldPickTheSameFolder() {
        for (preferences, expected) in [(["pt-BR"], "pt-BR"), (["pt"], "pt-BR"), (["pt-PT"], "pt-BR"), (["fr"], "en")] {
            #expect(Bundle.preferredLocalizations(from: shipped, forPreferences: preferences).first == expected, "\(preferences)")
        }
    }
}

/// The .lproj folders beside each catalog are what `xcstringstool compile` makes of it, so a
/// SwiftPM that doesn't compile catalogs itself still ships every language.
@Suite struct CompiledCatalogTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalogs = [
        "Sources/EbbCore/Resources/EbbCore.xcstrings",
        "Sources/Ebb/Resources/Localizable.xcstrings",
        "Sources/Ebb/Resources/AppShortcuts.xcstrings",
    ]
    private static let tool: String? = {
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "xcstringstool"]
        let output = Pipe()
        xcrun.standardOutput = output
        xcrun.standardError = FileHandle.nullDevice
        guard (try? xcrun.run()) != nil else { return nil }
        xcrun.waitUntilExit()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return xcrun.terminationStatus == 0 && !path.isEmpty ? path : nil
    }()

    @Test(.enabled(if: tool != nil, "xcstringstool not found: install Xcode to check that the committed .lproj folders match the catalogs"), arguments: catalogs)
    func theCommittedFoldersAreWhatTheCatalogCompilesTo(catalog: String) throws {
        let source = Self.root.appending(path: catalog)
        let fresh = FileManager.default.temporaryDirectory.appending(path: "ebb-xcstrings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fresh) }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: try #require(Self.tool))
        compile.arguments = ["compile", source.path, "--output-directory", fresh.path]
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0)

        let table = source.deletingPathExtension().lastPathComponent
        let produced = try Self.plists(of: table, under: fresh)
        let committed = try Self.plists(of: table, under: source.deletingLastPathComponent())
        #expect(!produced.isEmpty)
        #expect(Set(produced.keys) == Set(committed.keys), "\(catalog)")
        for (name, plist) in produced {
            #expect(committed[name] == plist, "\(catalog): \(name)")
        }
    }

    /// `lang.lproj/Table.ext` to its contents, read as a plist so formatting differences between
    /// Xcode versions don't count.
    private static func plists(of table: String, under folder: URL) throws -> [String: NSDictionary] {
        var plists: [String: NSDictionary] = [:]
        let manager = FileManager.default
        for lproj in try manager.contentsOfDirectory(atPath: folder.path) where lproj.hasSuffix(".lproj") {
            for file in try manager.contentsOfDirectory(atPath: folder.appending(path: lproj).path) where file.hasPrefix(table + ".") {
                let data = try Data(contentsOf: folder.appending(path: "\(lproj)/\(file)"))
                plists["\(lproj)/\(file)"] = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
            }
        }
        return plists
    }
}
