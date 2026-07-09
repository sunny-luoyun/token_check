import Foundation

struct PricingPeriod: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var label: String
    var effectiveFrom: Date
    var effectiveTo: Date?
    var inputMissPricePerMillion: Double
    var cacheHitPricePerMillion: Double
    var outputPricePerMillion: Double
    var reasoningPricePerMillion: Double
    var timeWindows: [TimeWindow]?
}

struct TimeWindow: Codable, Identifiable, Hashable {
    var id: String { "\(startHour)-\(endHour)" }
    var label: String
    var startHour: Int
    var endHour: Int
    var priceMultiplier: Double
}

struct ModelPricingRule: Codable, Identifiable, Hashable {
    static let defaultInputMissPricePerMillion = 0.14
    static let defaultCacheHitPricePerMillion = 0.0028
    static let defaultOutputPricePerMillion = 0.28
    static let defaultReasoningPricePerMillion = 0.28

    let providerID: String
    let modelId: String
    let variant: String
    var isEnabled: Bool = true
    var periods: [PricingPeriod]

    var id: String { pricingKey }

    var pricingKey: String {
        "\(providerID)/\(modelId)/\(variant)"
    }

    var displayName: String {
        let name = variant == "default" || variant == "max" ? modelId : "\(modelId) (\(variant))"
        if providerID == "opencode" { return name }
        return "[\(providerID)] \(name)"
    }

    var usesDefaultPricing: Bool {
        periods.allSatisfy { period in
            period.inputMissPricePerMillion == Self.defaultInputMissPricePerMillion
                && period.cacheHitPricePerMillion == Self.defaultCacheHitPricePerMillion
                && period.outputPricePerMillion == Self.defaultOutputPricePerMillion
                && period.reasoningPricePerMillion == Self.defaultReasoningPricePerMillion
                && (period.timeWindows == nil || period.timeWindows!.isEmpty)
        }
    }

    enum CodingKeys: String, CodingKey {
        case providerID
        case modelId
        case variant
        case isEnabled
        case inputMissPricePerMillion
        case cacheHitPricePerMillion
        case outputPricePerMillion
        case reasoningPricePerMillion
        case periods
    }

    init(
        providerID: String,
        modelId: String,
        variant: String,
        isEnabled: Bool = true,
        periods: [PricingPeriod]
    ) {
        self.providerID = providerID
        self.modelId = modelId
        self.variant = variant
        self.isEnabled = isEnabled
        self.periods = periods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? "opencode"
        modelId = try container.decode(String.self, forKey: .modelId)
        variant = try container.decode(String.self, forKey: .variant)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        if let periods = try container.decodeIfPresent([PricingPeriod].self, forKey: .periods), !periods.isEmpty {
            self.periods = periods
        } else {
            let inputMiss = try container.decode(Double.self, forKey: .inputMissPricePerMillion)
            let cacheHit = try container.decode(Double.self, forKey: .cacheHitPricePerMillion)
            let output = try container.decode(Double.self, forKey: .outputPricePerMillion)
            let reasoning = try container.decodeIfPresent(Double.self, forKey: .reasoningPricePerMillion) ?? Self.defaultReasoningPricePerMillion
            self.periods = [PricingPeriod(
                label: "默认",
                effectiveFrom: Date.distantPast,
                effectiveTo: nil,
                inputMissPricePerMillion: inputMiss,
                cacheHitPricePerMillion: cacheHit,
                outputPricePerMillion: output,
                reasoningPricePerMillion: reasoning,
                timeWindows: nil
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(variant, forKey: .variant)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(periods, forKey: .periods)
        if let first = periods.first {
            try container.encode(first.inputMissPricePerMillion, forKey: .inputMissPricePerMillion)
            try container.encode(first.cacheHitPricePerMillion, forKey: .cacheHitPricePerMillion)
            try container.encode(first.outputPricePerMillion, forKey: .outputPricePerMillion)
            try container.encode(first.reasoningPricePerMillion, forKey: .reasoningPricePerMillion)
        }
    }

    func price(at date: Date) -> (inputMiss: Double, cacheHit: Double, output: Double, reasoning: Double) {
        guard let period = periods.first(where: {
            date >= $0.effectiveFrom && ($0.effectiveTo == nil || date < $0.effectiveTo!)
        }) else {
            return (Self.defaultInputMissPricePerMillion,
                    Self.defaultCacheHitPricePerMillion,
                    Self.defaultOutputPricePerMillion,
                    Self.defaultReasoningPricePerMillion)
        }
        let hour = Calendar.current.component(.hour, from: date)
        if let windows = period.timeWindows,
           let window = windows.first(where: { hour >= $0.startHour && hour < $0.endHour }) {
            return (
                period.inputMissPricePerMillion * window.priceMultiplier,
                period.cacheHitPricePerMillion * window.priceMultiplier,
                period.outputPricePerMillion * window.priceMultiplier,
                period.reasoningPricePerMillion * window.priceMultiplier
            )
        }
        return (period.inputMissPricePerMillion,
                period.cacheHitPricePerMillion,
                period.outputPricePerMillion,
                period.reasoningPricePerMillion)
    }

    static func defaults(providerID: String, modelId: String, variant: String) -> ModelPricingRule {
        ModelPricingRule(
            providerID: providerID,
            modelId: modelId,
            variant: variant,
            isEnabled: true,
            periods: [PricingPeriod(
                label: "默认",
                effectiveFrom: Date.distantPast,
                effectiveTo: nil,
                inputMissPricePerMillion: defaultInputMissPricePerMillion,
                cacheHitPricePerMillion: defaultCacheHitPricePerMillion,
                outputPricePerMillion: defaultOutputPricePerMillion,
                reasoningPricePerMillion: defaultReasoningPricePerMillion,
                timeWindows: nil
            )]
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

    static func rule(forModelId modelId: String, variant: String, providerID: String = "opencode", rules: [ModelPricingRule]) -> ModelPricingRule {
        lookup(from: rules)["\(providerID)/\(modelId)/\(variant)"] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
    }

    static func isEnabled(forModelId modelId: String, variant: String, providerID: String = "opencode", rules: [ModelPricingRule]) -> Bool {
        lookup(from: rules)["\(providerID)/\(modelId)/\(variant)"]?.isEnabled ?? true
    }

    static func price(forModelId modelId: String, variant: String, providerID: String = "opencode", at date: Date, rules: [ModelPricingRule]) -> (inputMiss: Double, cacheHit: Double, output: Double, reasoning: Double) {
        let model = lookup(from: rules)["\(providerID)/\(modelId)/\(variant)"] ?? .defaults(providerID: providerID, modelId: modelId, variant: variant)
        return model.price(at: date)
    }
}
