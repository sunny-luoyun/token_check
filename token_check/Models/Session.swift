import Foundation

struct Session: Identifiable {
    let id: String
    let slug: String?
    let title: String?
    let tokensInput: Int
    let tokensOutput: Int
    let tokensReasoning: Int
    let tokensCacheRead: Int
    let tokensCacheWrite: Int
    let cost: Double
    let modelId: String
    let modelVariant: String
    let timeCreated: Date
    let project: String?

    var modelDisplayName: String {
        modelVariant == "default" || modelVariant == "max" ? modelId : "\(modelId) (\(modelVariant))"
    }
}
