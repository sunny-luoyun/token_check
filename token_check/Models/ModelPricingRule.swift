import Foundation

struct ModelPricingRule: Codable, Identifiable, Hashable {
    static let defaultInputMissPricePerMillion = 1.0
    static let defaultCacheHitPricePerMillion = 0.02
    static let defaultOutputPricePerMillion = 2.0
    static let defaultReasoningPricePerMillion = 2.0

    let modelId: String
    let variant: String
    var isEnabled: Bool = true
    var inputMissPricePerMillion: Double
    var cacheHitPricePerMillion: Double
    var outputPricePerMillion: Double
    var reasoningPricePerMillion: Double

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
            && reasoningPricePerMillion == Self.defaultReasoningPricePerMillion
    }

    enum CodingKeys: String, CodingKey {
        case modelId
        case variant
        case isEnabled
        case inputMissPricePerMillion
        case cacheHitPricePerMillion
        case outputPricePerMillion
        case reasoningPricePerMillion
    }

    init(
        modelId: String,
        variant: String,
        isEnabled: Bool = true,
        inputMissPricePerMillion: Double,
        cacheHitPricePerMillion: Double,
        outputPricePerMillion: Double,
        reasoningPricePerMillion: Double = defaultReasoningPricePerMillion
    ) {
        self.modelId = modelId
        self.variant = variant
        self.isEnabled = isEnabled
        self.inputMissPricePerMillion = inputMissPricePerMillion
        self.cacheHitPricePerMillion = cacheHitPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.reasoningPricePerMillion = reasoningPricePerMillion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decode(String.self, forKey: .modelId)
        variant = try container.decode(String.self, forKey: .variant)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        inputMissPricePerMillion = try container.decode(Double.self, forKey: .inputMissPricePerMillion)
        cacheHitPricePerMillion = try container.decode(Double.self, forKey: .cacheHitPricePerMillion)
        outputPricePerMillion = try container.decode(Double.self, forKey: .outputPricePerMillion)
        reasoningPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .reasoningPricePerMillion) ?? ModelPricingRule.defaultReasoningPricePerMillion
    }

    static func defaults(modelId: String, variant: String) -> ModelPricingRule {
        ModelPricingRule(
            modelId: modelId,
            variant: variant,
            isEnabled: true,
            inputMissPricePerMillion: defaultInputMissPricePerMillion,
            cacheHitPricePerMillion: defaultCacheHitPricePerMillion,
            outputPricePerMillion: defaultOutputPricePerMillion,
            reasoningPricePerMillion: defaultReasoningPricePerMillion
        )
    }
}

enum ModelPricingStore {
    static let storageKey = "modelPricingRules"

    static func load() -> [ModelPricingRule] {
        SharedStorage.store.read(storageKey, type: [ModelPricingRule].self) ?? []
    }

    static func save(_ rules: [ModelPricingRule]) {
        SharedStorage.store.write(storageKey, value: rules)
    }

    static func lookup(from rules: [ModelPricingRule]) -> [String: ModelPricingRule] {
        Dictionary(uniqueKeysWithValues: rules.map { ($0.pricingKey, $0) })
    }

    static func rule(forModelId modelId: String, variant: String, rules: [ModelPricingRule]) -> ModelPricingRule {
        lookup(from: rules)["\(modelId)/\(variant)"] ?? .defaults(modelId: modelId, variant: variant)
    }

    static func isEnabled(forModelId modelId: String, variant: String, rules: [ModelPricingRule]) -> Bool {
        lookup(from: rules)["\(modelId)/\(variant)"]?.isEnabled ?? true
    }
}
