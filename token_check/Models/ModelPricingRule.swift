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
    var inputMissPricePerMillion: Double
    var cacheHitPricePerMillion: Double
    var outputPricePerMillion: Double
    var reasoningPricePerMillion: Double

    fileprivate var pendingMultiplier: Double?

    init(
        label: String,
        startHour: Int,
        endHour: Int,
        inputMissPricePerMillion: Double,
        cacheHitPricePerMillion: Double,
        outputPricePerMillion: Double,
        reasoningPricePerMillion: Double
    ) {
        self.label = label
        self.startHour = startHour
        self.endHour = endHour
        self.inputMissPricePerMillion = inputMissPricePerMillion
        self.cacheHitPricePerMillion = cacheHitPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.reasoningPricePerMillion = reasoningPricePerMillion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        startHour = try container.decode(Int.self, forKey: .startHour)
        endHour = try container.decode(Int.self, forKey: .endHour)
        inputMissPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .inputMissPricePerMillion) ?? 0
        cacheHitPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .cacheHitPricePerMillion) ?? 0
        outputPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .outputPricePerMillion) ?? 0
        reasoningPricePerMillion = try container.decodeIfPresent(Double.self, forKey: .reasoningPricePerMillion) ?? 0
        pendingMultiplier = try container.decodeIfPresent(Double.self, forKey: .priceMultiplier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(startHour, forKey: .startHour)
        try container.encode(endHour, forKey: .endHour)
        try container.encode(inputMissPricePerMillion, forKey: .inputMissPricePerMillion)
        try container.encode(cacheHitPricePerMillion, forKey: .cacheHitPricePerMillion)
        try container.encode(outputPricePerMillion, forKey: .outputPricePerMillion)
        try container.encode(reasoningPricePerMillion, forKey: .reasoningPricePerMillion)
    }

    enum CodingKeys: String, CodingKey {
        case label, startHour, endHour
        case inputMissPricePerMillion, cacheHitPricePerMillion, outputPricePerMillion, reasoningPricePerMillion
        case priceMultiplier
    }
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
                && (period.timeWindows == nil || period.timeWindows!.isEmpty
                    || period.timeWindows!.allSatisfy { window in
                        window.inputMissPricePerMillion == Self.defaultInputMissPricePerMillion
                            && window.cacheHitPricePerMillion == Self.defaultCacheHitPricePerMillion
                            && window.outputPricePerMillion == Self.defaultOutputPricePerMillion
                            && window.reasoningPricePerMillion == Self.defaultReasoningPricePerMillion
                    })
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
            self.periods = Self.migrateTimeWindows(in: periods)
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

    private static func migrateTimeWindows(in periods: [PricingPeriod]) -> [PricingPeriod] {
        periods.map { period in
            var period = period
            period.timeWindows = period.timeWindows?.map { window in
                var window = window
                if let m = window.pendingMultiplier {
                    window.inputMissPricePerMillion = period.inputMissPricePerMillion * m
                    window.cacheHitPricePerMillion = period.cacheHitPricePerMillion * m
                    window.outputPricePerMillion = period.outputPricePerMillion * m
                    window.reasoningPricePerMillion = period.reasoningPricePerMillion * m
                }
                return window
            }
            return period
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
                window.inputMissPricePerMillion,
                window.cacheHitPricePerMillion,
                window.outputPricePerMillion,
                window.reasoningPricePerMillion
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
