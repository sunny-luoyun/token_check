import Foundation
import SQLite3

final class DiskCleanupService {
    private let dbPath: String
    private let devecoPath: String

    init() {
        dbPath = AppDatabase.opencodePath
        devecoPath = AppDatabase.devecoPath
    }

    func fetchDiskUsage() throws -> DiskUsage {
        let ocAttrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        let ocSize = ocAttrs[.size] as? Int64 ?? 0
        let dcSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: devecoPath))?[.size] as? Int64 ?? 0

        var ptr: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &ptr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = ptr else {
            throw DatabaseError.cannotOpen(dbPath)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let ocSessions = try scalarInt(db, "SELECT COUNT(*) FROM session")
        let ocMessages = try scalarInt(db, "SELECT COUNT(*) FROM message")
        let ocParts    = try scalarInt(db, "SELECT COUNT(*) FROM part")
        let ocEvents   = try scalarInt(db, "SELECT COUNT(*) FROM event")

        var dcSessions = 0, dcMessages = 0, dcParts = 0, dcEvents = 0
        if AppDatabase.devecoExists, let dc = openDevecoDB() {
            dcSessions = (try? scalarInt(dc, "SELECT COUNT(*) FROM session")) ?? 0
            dcMessages = (try? scalarInt(dc, "SELECT COUNT(*) FROM message")) ?? 0
            dcParts    = (try? scalarInt(dc, "SELECT COUNT(*) FROM part")) ?? 0
            dcEvents   = (try? scalarInt(dc, "SELECT COUNT(*) FROM event")) ?? 0
            sqlite3_close(dc)
        }

        let dsh = fetchDshUsage()

        return DiskUsage(
            dbFileSize: formatBytes(ocSize + dcSize),
            sessionCount: ocSessions + dcSessions,
            messageCount: ocMessages + dcMessages,
            partCount: ocParts + dcParts,
            eventCount: ocEvents + dcEvents,
            dbSizeBytes: ocSize + dcSize,
            dshFileSize: formatBytes(dsh.sizeBytes),
            dshSizeBytes: dsh.sizeBytes,
            dshSessionCount: dsh.sessionCount,
            dshMessageCount: dsh.messageCount,
            dshEventCount: dsh.eventCount
        )
    }

    func cleanupMessages() throws {
        var ptr: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &ptr, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = ptr else {
            throw DatabaseError.cannotOpen(dbPath)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30_000)

        try exec(db, "DELETE FROM message")
        try exec(db, "VACUUM")
    }

    private func openDevecoDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(devecoPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    // MARK: - DSH 用量

    /// DSH 用量：sessions/ 目录全部文件 + storages/ 目录全部文件。
    /// 会话数 = sessions/ 下会话目录数；消息/事件数来自 DshEventStore（zstd 不可用时为 0）。
    private func fetchDshUsage() -> (sizeBytes: Int64, sessionCount: Int, messageCount: Int, eventCount: Int) {
        guard let home = DshService.dshHomePath else { return (0, 0, 0, 0) }
        let fm = FileManager.default
        let sessionsDir = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        let storagesDir = URL(fileURLWithPath: home).appendingPathComponent("storages")

        let sessionsSize = directorySize(sessionsDir)
        let storagesSize = directorySize(storagesDir)

        let sessionCount = countSessionDirs(sessionsDir)

        var messageCount = 0
        var eventCount = 0
        let all = DshEventStore.shared.loadAll()
        for item in all.values {
            messageCount += item.userMessages + item.assistantMessages
            eventCount += item.events.count
        }

        return (sessionsSize + storagesSize, sessionCount, messageCount, eventCount)
    }

    /// 递归求和目录下所有文件的逻辑字节大小（含子目录）；目录不存在返回 0。
    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 统计 sessions/ 下的一级会话目录数；目录不存在返回 0。
    private func countSessionDirs(_ sessionsDir: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for url in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                count += 1
            }
        }
        return count
    }

    // MARK: - Helpers

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw DatabaseError.prepareError(msg)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIdx = 0
        while value >= 1024, unitIdx < units.count - 1 {
            value /= 1024
            unitIdx += 1
        }
        return String(format: "%.2f %@", value, units[unitIdx])
    }
}
