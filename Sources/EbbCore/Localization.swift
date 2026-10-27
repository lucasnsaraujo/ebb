import Foundation

/// EbbCore's user-facing strings live in its own catalog, `EbbCore.xcstrings`, compiled into the
/// package's resource bundle, so `swift test` reads them without an app around. The app copies
/// that bundle into its Resources, where `Bundle.module` looks first.
enum Localization {
    private static let table = "EbbCore"
    private static let catalog = Bundle.module

    /// `.autoupdatingCurrent` follows the language the app runs in; any other locale picks that
    /// language's strings, so a test can ask for Portuguese on an English Mac. The language comes
    /// from the main bundle, not the catalog, so a test run (whose main bundle has no languages)
    /// reads English whatever the Mac is set to.
    static func text(_ key: String.LocalizationValue, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: key, table: table, bundle: bundle(for: locale), locale: locale)
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let preferences = locale == .autoupdatingCurrent ? Bundle.main.preferredLocalizations : [locale.identifier]
        let language = Bundle.preferredLocalizations(from: catalog.localizations, forPreferences: preferences).first
        return language.flatMap { catalog.url(forResource: $0, withExtension: "lproj") }.flatMap(Bundle.init(url:)) ?? catalog
    }
}
