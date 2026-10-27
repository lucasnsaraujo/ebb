import Foundation

/// EbbCore's user-facing strings live in `EbbCore.xcstrings`, shipped as the .lproj folders beside
/// it in the package's resource bundle, so `swift test` reads them without an app around. The app
/// copies that bundle into its Resources, where `Bundle.module` looks first.
enum Localization {
    private static let table = "EbbCore"
    private static let catalog = Bundle.module

    /// `.autoupdatingCurrent` follows the language the app runs in; any other locale picks that
    /// language's strings, so a test can ask for Portuguese on an English Mac. The app's language
    /// is the main bundle's choice, so these strings and SwiftUI's agree, and a test run (whose
    /// main bundle has no languages) reads English whatever the Mac is set to.
    static func text(_ key: String.LocalizationValue, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: key, table: table, bundle: bundle(for: locale), locale: locale)
    }

    /// The shipped language for a list of BCP 47 tags, most preferred first: the first tag with an
    /// exact match, else the first shipped language sharing its language subtag, so "pt" and "pt-PT"
    /// read pt-BR. `nil` when none matches, and the development language stands.
    static func language(for preferences: [String], among localizations: [String]) -> String? {
        let shipped = localizations.map { (tag: $0, subtags: subtags(of: $0)) }
        for preference in preferences.map(subtags(of:)) {
            if let exact = shipped.first(where: { $0.subtags == preference }) { return exact.tag }
            if let sameLanguage = shipped.first(where: { $0.subtags.first == preference.first }) { return sameLanguage.tag }
        }
        return nil
    }

    /// "pt_BR", "PT-br" and "pt-BR" are one tag; so are the folder names some build systems lowercase.
    private static func subtags(of tag: String) -> [String] {
        tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let preferences = locale == .autoupdatingCurrent ? Bundle.main.preferredLocalizations : [locale.identifier(.bcp47)]
        let language = language(for: preferences, among: catalog.localizations)
        return language.flatMap { catalog.url(forResource: $0, withExtension: "lproj") }.flatMap(Bundle.init(url:)) ?? catalog
    }
}
