import Foundation

struct DiskUsage: Codable {
    let dbFileSize: String
    let sessionCount: Int
    let messageCount: Int
    let partCount: Int
    let eventCount: Int
    let dbSizeBytes: Int64

    // DSH 数据（~/.dsh/sessions + storages）
    // 注：无 decode 路径，5 个新字段均非可选；若未来持久化/反序列化需加默认值
    let dshFileSize: String
    let dshSizeBytes: Int64
    let dshSessionCount: Int
    let dshMessageCount: Int
    let dshEventCount: Int
}
