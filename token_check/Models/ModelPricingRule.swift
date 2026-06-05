import Foundation

struct ModelPricingRule: Codable, Identifiable, Hashable {
    static let defaultInputMissPricePerMillion = 1.0
    static let defaultCacheHitPricePerMillion = 0.02
    static let defaultOutputPricePerMillion = 2.0

    let modelId: String
    let variant: String
    var inputMissPricePerMillion: Double
    var cacheHitPricePerMillion: Double
    var outputPricePerMillion: Double

    var id: String { pricingKey }

    var pricingKey: String {
        "\(modelId)/\(variant)"
    }

    var displayName: String {
        variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
    }

    var usesDefaultPricing: Bool {
        inputMissPricePerMillion == Self.defaultInputMissPricePerMillion
            && cacheHitPricePerMillion == Self.defaultCacheHitPricePerMillion
            && outputPricePerMillion == Self.defaultOutputPricePerMillion
    }

    static func defaults(modelId: String, variant: String) -> ModelPricingRule {
        ModelPricingRule(
            modelId: modelId,
            variant: variant,
            inputMissPricePerMillion: defaultInputMissPricePerMillion,
            cacheHitPricePerMillion: defaultCacheHitPricePerMillion,
            outputPricePerMillion: defaultOutputPricePerMillion
        )
    }
}

enum ModelPricingStore {
    static let storageKey = "modelPricingRules"

    static func load(from defaults: UserDefaults = .standard) -> [ModelPricingRule] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ModelPricingRule].self, from: data)) ?? []
    }

    static func save(_ rules: [ModelPricingRule], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func lookup(from rules: [ModelPricingRule]) -> [String: ModelPricingRule] {
        Dictionary(uniqueKeysWithValues: rules.map { ($0.pricingKey, $0) })
    }

    static func rule(forModelId modelId: String, variant: String, rules: [ModelPricingRule]) -> ModelPricingRule {
        lookup(from: rules)["\(modelId)/\(variant)"] ?? .defaults(modelId: modelId, variant: variant)
    }
}
