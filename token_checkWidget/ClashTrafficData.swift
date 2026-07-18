import Foundation

struct ClashTrafficData: Codable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64
    let label: String
    let lastUpdated: Date

    var used: Int64 { upload + download }
    var remaining: Int64 { total - used }
    var progress: Double { total > 0 ? min(Double(used) / Double(total), 1.0) : 0 }
    var expireDate: Date { Date(timeIntervalSince1970: TimeInterval(expire)) }
    var isValid: Bool { total > 0 }
}
