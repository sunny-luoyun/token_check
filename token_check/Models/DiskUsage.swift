import Foundation

struct DiskUsage: Codable {
    let dbFileSize: String
    let sessionCount: Int
    let messageCount: Int
    let partCount: Int
    let eventCount: Int
    let dbSizeBytes: Int64
}
