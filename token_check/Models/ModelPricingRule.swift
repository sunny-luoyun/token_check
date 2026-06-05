import Foundation

struct ModelPricingRule: Codable, Identifiable, Hashable {
    static let defaultInputMissPricePerMillion = 1.0
    static let defaultCacheHitPricePerMillion = 0.02
    static let defaultOutputPricePerMillion = 2.0

    let modelId: String
    let variant: String
    var isEnabled: Bool = true
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

    enum CodingKeys: String, CodingKey {
        case modelId
        case variant
        case isEnabled
        case inputMissPricePerMillion
        case cacheHitPricePerMillion
        case outputPricePerMillion
    }

    init(
        modelId: String,
        variant: String,
        isEnabled: Bool = true,
        inputMissPricePerMillion: Double,
        cacheHitPricePerMillion: Double,
        outputPricePerMillion: Double
    ) {
        self.modelId = modelId
        self.variant = variant
        self.isEnabled = isEnabled
        self.inputMissPricePerMillion = inputMissPricePerMillion
        self.cacheHitPricePerMillion = cacheHitPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decode(String.self, forKey: .modelId)
        variant = try container.decode(String.self, forKey: .variant)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        inputMissPricePerMillion = try container.decode(Double.self, forKey: .inputMissPricePerMillion)
        cacheHitPricePerMillion = try container.decode(Double.self, forKey: .cacheHitPricePerMillion)
        outputPricePerMillion = try container.decode(Double.self, forKey: .outputPricePerMillion)
    }

    static func defaults(modelId: String, variant: String) -> ModelPricingRule {
        ModelPricingRule(
            modelId: modelId,
            variant: variant,
            isEnabled: true,
            inputMissPricePerMillion: defaultInputMissPricePerMillion,
            cacheHitPricePerMillion: defaultCacheHitPricePerMillion,
            outputPricePerMillion: defaultOutputPricePerMillion
        )
    }
}

enum ModelPricingStore {
    static let appGroupIdentifier = "group.com.luoyun.tokencheck"
    static let storageKey = "modelPricingRules"
    static let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)

    static func load(from defaults: UserDefaults? = nil) -> [ModelPricingRule] {
        migrateIfNeeded()
        let defaults = defaults ?? effectiveDefaults
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ModelPricingRule].self, from: data)) ?? []
    }

    static func save(_ rules: [ModelPricingRule], to defaults: UserDefaults? = nil) {
        migrateIfNeeded()
        let defaults = defaults ?? effectiveDefaults
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
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

    private static var effectiveDefaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    private static func migrateIfNeeded() {
        guard let sharedDefaults else { return }
        guard sharedDefaults.data(forKey: storageKey) == nil,
              let legacyData = UserDefaults.standard.data(forKey: storageKey) else { return }
        sharedDefaults.set(legacyData, forKey: storageKey)
    }
}
