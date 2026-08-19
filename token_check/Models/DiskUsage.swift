import Foundation

struct DiskUsage: Codable {
    let dbFileSize: String
    let sessionCount: Int
    let messageCount: Int
    let partCount: Int
    let eventCount: Int
    let dbSizeBytes: Int64

    // DSH 数据（~/.dsh/sessions + storages）
    let dshFileSize: String
    let dshSizeBytes: Int64
    let dshSessionCount: Int
    let dshMessageCount: Int
    let dshEventCount: Int
}
