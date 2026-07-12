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

        return DiskUsage(
            dbFileSize: formatBytes(ocSize + dcSize),
            sessionCount: ocSessions + dcSessions,
            messageCount: ocMessages + dcMessages,
            partCount: ocParts + dcParts,
            eventCount: ocEvents + dcEvents,
            dbSizeBytes: ocSize + dcSize
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
