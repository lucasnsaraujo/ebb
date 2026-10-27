import Foundation

/// A plan's default size relative to its provider's base plan, and where the number comes from.
public struct PlanDefault: Sendable, Equatable, Identifiable {
    /// The plan as the provider names it, lowercased: "max_20x", "plus", "level_basic".
    /// `PlanWeights.anyPlan` covers every plan of a provider that reports none or whose sizes are unknown.
    public var plan: String
    public var title: String
    public var weight: Double
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
public enum PlanWeights {
    public static let anyPlan = "*"

    private static let openAIPricing = "OpenAI's Codex pricing page gives this plan Plus's per-seat limits."
    private static let poolWidget = "Estimate from CLIProxyPoolWidget's defaults; OpenAI publishes no multiplier."
    private static let noSizes = "Guess: the provider reports no plan sizes, so every login counts the same."

    public static let defaults: [String: [PlanDefault]] = [
        "claude": [
            PlanDefault(plan: "pro", title: "Pro", weight: 1, source: "Base plan.", isGuess: false),
            PlanDefault(plan: "max_5x", title: "Max 5x", weight: 5, source: "The tier name carries the multiplier.", isGuess: false),
            PlanDefault(plan: "max_20x", title: "Max 20x", weight: 20, source: "The tier name carries the multiplier.", isGuess: false),
        ],
        "codex": [
            PlanDefault(plan: "free", title: "Free", weight: 0.1, source: "Guess: OpenAI gives Free no number.", isGuess: true),
            PlanDefault(plan: "go", title: "Go", weight: 0.4, source: "Guess: OpenAI gives Go no number.", isGuess: true),
            PlanDefault(plan: "plus", title: "Plus", weight: 1, source: "Base plan.", isGuess: false),
            PlanDefault(plan: "team", title: "Team", weight: 1, source: openAIPricing, isGuess: false),
            PlanDefault(plan: "business", title: "Business", weight: 1, source: openAIPricing, isGuess: false),
            PlanDefault(plan: "enterprise", title: "Enterprise", weight: 1, source: openAIPricing, isGuess: false),
            PlanDefault(plan: "edu", title: "Edu", weight: 1, source: openAIPricing, isGuess: false),
            PlanDefault(plan: "prolite", title: "Pro 100", weight: 10, source: poolWidget, isGuess: true),
            PlanDefault(plan: "pro", title: "Pro 200", weight: 20, source: poolWidget, isGuess: true),
            PlanDefault(plan: "promax", title: "Pro 500", weight: 50, source: "Guess: Pro 200's weight scaled by price.", isGuess: true),
        ],
        "devin": [PlanDefault(plan: anyPlan, title: "Any plan", weight: 1, source: noSizes, isGuess: true)],
        "antigravity": [PlanDefault(plan: anyPlan, title: "Any plan", weight: 1, source: noSizes, isGuess: true)],
        "meta": [PlanDefault(plan: anyPlan, title: "Any plan", weight: 1, source: noSizes, isGuess: true)],
        "kimi": [
            PlanDefault(plan: "level_free", title: "Adagio", weight: 0.25, source: "Guess: free tier, no published quota.", isGuess: true),
            PlanDefault(plan: "level_trial", title: "Andante", weight: 1, source: "Base plan: 1,024 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_basic", title: "Moderato", weight: 2, source: "2,048 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_intermediate", title: "Allegretto", weight: 7, source: "7,168 requests a week (CodexBar's Kimi notes).", isGuess: false),
            PlanDefault(plan: "level_advanced", title: "Allegro", weight: 14, source: "Guess: twice Allegretto.", isGuess: true),
            PlanDefault(plan: anyPlan, title: "Other plans", weight: 1, source: "Guess: counted like the base plan.", isGuess: true),
        ],
    ]

    /// `UserDefaults` key of the overrides dictionary.
    public static let overridesKey = "planWeightOverrides"

    public static func overrideKey(provider: String, plan: String) -> String {
        "\(provider)/\(plan)"
    }

    /// The default for a plan: its table entry, then Claude's "_Nx" tier multiplier,
    /// then the provider's any-plan entry. `nil` when the plan's size isn't known.
    public static func defaultWeight(provider: String, plan: String?) -> Double? {
        let table = defaults[provider] ?? []
        if let plan = plan?.lowercased(), let entry = table.first(where: { $0.plan == plan }) { return entry.weight }
        if provider == "claude", let plan {
            return ClaudeProvider.plan(rateLimitTier: plan, subscriptionStatus: "active").weight.nonZero
        }
        return table.first { $0.plan == anyPlan }?.weight
    }

    /// The weight a plan counts with: the user's override for its table row, else the default.
    /// A plan without a row of its own falls under the provider's any-plan row. Overrides of zero or less are ignored.
    public static func weight(provider: String, plan: String?, overrides: [String: Double]) -> Double? {
        if let row = row(provider: provider, plan: plan),
           let override = overrides[overrideKey(provider: provider, plan: row)], override > 0 {
            return override
        }
        return defaultWeight(provider: provider, plan: plan)
    }

    private static func row(provider: String, plan: String?) -> String? {
        let table = defaults[provider] ?? []
        if let plan = plan?.lowercased(), table.contains(where: { $0.plan == plan }) { return plan }
        return table.contains { $0.plan == anyPlan } ? anyPlan : plan?.lowercased()
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
