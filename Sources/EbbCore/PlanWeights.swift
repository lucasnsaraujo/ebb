import Foundation

/// A plan's default size relative to its provider's base plan, and where the number comes from.
public struct PlanDefault: Sendable, Equatable, Identifiable {
    /// The plan as the provider names it, lowercased: "max_20x", "plus", "level_basic".
    /// `PlanWeights.anyPlan` covers every plan of a provider that reports none or whose sizes are unknown.
    public var plan: String
    public var title: String
    public var weight: PlanWeight
    /// The source of `weight`, or why it's a guess.
    public var source: String
    public var isGuess: Bool

    public var id: String { plan }

    /// `title` and `source` as Settings shows them; the English above is the catalog key.
    /// Plan names the provider coined, like "Max 5x", have no entry and read as they are.
    public var localizedTitle: String { Localization.text(String.LocalizationValue(title)) }
    public var localizedSource: String { Localization.text(String.LocalizationValue(source)) }
}

/// Every default plan weight, in one place. Weights only ever compare plans of the same
/// provider: pools are never blended across providers. Users can override each in Settings.
///
/// Claude's windows scale differently. Per 5-hour session, Anthropic's plan pages give Max 5x
/// and Max 20x 5 and 20 times Pro. Their weeks are closer: Botfarm's usage-API readings (Feb 2026)
/// put a full 5-hour window at 8.2–8.9% of Max 5x's week and 15.1% of Max 20x's, a Max 20x week
/// about 2.1 times Max 5x's; Anthropic's Aug 2025 hour ranges give 1.7 times, and Max 5x 3.5 times
/// Pro. The defaults take twice. Other providers publish no weekly ratio, so one weight fills both windows.
public enum PlanWeights {
    public static let anyPlan = "*"

    private static let openAIPricing = "OpenAI's Codex pricing page gives this plan Plus's per-seat limits."
    private static let poolWidget = "Estimate from CLIProxyPoolWidget's defaults; OpenAI publishes no multiplier."
    private static let noSizes = "Guess: the provider reports no plan sizes, so every login counts the same."

    public static let defaults: [String: [PlanDefault]] = [
        "claude": [
            PlanDefault(plan: "pro", title: "Pro", weight: PlanWeight(1), source: "Base plan.", isGuess: false),
            PlanDefault(plan: "max_5x", title: "Max 5x", weight: PlanWeight(session: 5, weekly: 3.5), source: "5 times Pro a session, about 3.5 times a week.", isGuess: false),
            PlanDefault(plan: "max_20x", title: "Max 20x", weight: PlanWeight(session: 20, weekly: 7), source: "20 times Pro a session, about twice Max 5x a week.", isGuess: false),
        ],
        "codex": [
            PlanDefault(plan: "free", title: "Free", weight: PlanWeight(0.1), source: "Guess: OpenAI gives Free no number.", isGuess: true),
            PlanDefault(plan: "go", title: "Go", weight: PlanWeight(0.4), source: "Guess: OpenAI gives Go no number.", isGuess: true),
            PlanDefault(plan: "plus", title: "Plus", weight: PlanWeight(1), source: "Base plan.", isGuess: false),
            PlanDefault(plan: "team", title: "Team", weight: PlanWeight(1), source: openAIPricing, isGuess: false),
            PlanDefault(plan: "business", title: "Business", weight: PlanWeight(1), source: openAIPricing, isGuess: false),
            PlanDefault(plan: "enterprise", title: "Enterprise", weight: PlanWeight(1), source: openAIPricing, isGuess: false),
            PlanDefault(plan: "edu", title: "Edu", weight: PlanWeight(1), source: openAIPricing, isGuess: false),
            PlanDefault(plan: "prolite", title: "Pro 100", weight: PlanWeight(10), source: poolWidget, isGuess: true),
            PlanDefault(plan: "pro", title: "Pro 200", weight: PlanWeight(20), source: poolWidget, isGuess: true),
            PlanDefault(plan: "promax", title: "Pro 500", weight: PlanWeight(50), source: "Guess: Pro 200's weight scaled by price.", isGuess: true),
        ],
        "devin": [PlanDefault(plan: anyPlan, title: "Any plan", weight: PlanWeight(1), source: noSizes, isGuess: true)],
        "antigravity": [PlanDefault(plan: anyPlan, title: "Any plan", weight: PlanWeight(1), source: noSizes, isGuess: true)],
        "meta": [PlanDefault(plan: anyPlan, title: "Any plan", weight: PlanWeight(1), source: noSizes, isGuess: true)],
        "kimi": [
            PlanDefault(plan: "level_free", title: "Adagio", weight: PlanWeight(0.25), source: "Guess: free tier, no published quota.", isGuess: true),
            PlanDefault(plan: "level_trial", title: "Andante", weight: PlanWeight(1), source: "Base plan: 1,024 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_basic", title: "Moderato", weight: PlanWeight(2), source: "2,048 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_intermediate", title: "Allegretto", weight: PlanWeight(7), source: "7,168 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_advanced", title: "Allegro", weight: PlanWeight(14), source: "Guess: twice Allegretto.", isGuess: true),
            PlanDefault(plan: anyPlan, title: "Other plans", weight: PlanWeight(1), source: "Guess: counted like the base plan.", isGuess: true),
        ],
    ]

    /// Max 5x's week, in its own 5-hour windows: a full window used 8.2–8.9% of its weekly meter
    /// (Botfarm, Feb 2026).
    static let claudeMax5xWeekInWindows = 11.8

    /// How many of the base plan's 5-hour windows its week holds, so routing can tell which
    /// window a login runs out of first. Claude's comes from Max 5x's measured week: 11.8 of its
    /// windows, at 5 Pros a session and 3.5 a week, is 11.8 × 5 / 3.5 ≈ 16.9 of Pro's. Max 20x's
    /// week then holds about 5.9 of its own windows (Botfarm: 6.6). Other providers publish no such
    /// count, so their week counts as one window: the lower of the two shares binds, as it always did.
    public static func weekInWindows(provider: String) -> Double {
        guard provider == ClaudeProvider().proxyName, let max5x = defaultWeight(provider: provider, plan: "max_5x") else { return 1 }
        return claudeMax5xWeekInWindows * max5x.session / max5x.weekly
    }

    /// `UserDefaults` key of the overrides dictionary.
    public static let overridesKey = "planWeightOverrides"

    /// A 5-hour override keeps the key a plan's one weight was saved under before plans had a
    /// weekly size, so a weight set back then sizes the 5-hour window and the week keeps its default.
    public static func overrideKey(provider: String, plan: String, window: PoolWindow) -> String {
        switch window {
        case .session: "\(provider)/\(plan)"
        case .weekly: "\(provider)/\(plan)/weekly"
        }
    }

    /// The default for a plan: its table entry, then for a Claude tier the table doesn't list, the
    /// listed tier with the same "_Nx" multiplier, then the provider's any-plan entry.
    /// `nil` when the plan's size isn't known.
    public static func defaultWeight(provider: String, plan: String?) -> PlanWeight? {
        let table = defaults[provider] ?? []
        if let plan = plan?.lowercased(), let entry = table.first(where: { $0.plan == plan }) { return entry.weight }
        if provider == ClaudeProvider().proxyName, let plan = plan?.lowercased() {
            guard !plan.contains("free") else { return nil }
            // Only the tiers above have a measured week; another multiplier fills both windows.
            guard let multiplier = ClaudeProvider.multiplier(rateLimitTier: plan) else { return PlanWeight(1) }
            return table.first { $0.weight.session == multiplier }?.weight ?? PlanWeight(multiplier)
        }
        return table.first { $0.plan == anyPlan }?.weight
    }

    /// The weight a plan counts with: the user's override for each window of its table row, else
    /// the default. A plan without a row of its own falls under the provider's any-plan row.
    /// Overrides of zero or less are ignored.
    public static func weight(provider: String, plan: String?, overrides: [String: Double]) -> PlanWeight? {
        guard var weight = defaultWeight(provider: provider, plan: plan) else { return nil }
        guard let row = row(provider: provider, plan: plan) else { return weight }
        func override(_ window: PoolWindow) -> Double? {
            overrides[overrideKey(provider: provider, plan: row, window: window)].flatMap { $0 > 0 ? $0 : nil }
        }
        weight.session = override(.session) ?? weight.session
        weight.weekly = override(.weekly) ?? weight.weekly
        return weight
    }

    private static func row(provider: String, plan: String?) -> String? {
        let table = defaults[provider] ?? []
        if let plan = plan?.lowercased(), table.contains(where: { $0.plan == plan }) { return plan }
        return table.contains { $0.plan == anyPlan } ? anyPlan : plan?.lowercased()
    }
}

