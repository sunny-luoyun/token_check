import Foundation
import SQLite3

final class DiskCleanupService {
    private let dbPath: String

    init() {
        dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
    }

    func fetchDiskUsage() throws -> DiskUsage {
        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        let fileSize = attrs[.size] as? Int64 ?? 0

        var ptr: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &ptr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = ptr else {
            throw DatabaseError.cannotOpen(dbPath)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        let sessionCount = try scalarInt(db, "SELECT COUNT(*) FROM session")
        let messageCount = try scalarInt(db, "SELECT COUNT(*) FROM message")
        let partCount    = try scalarInt(db, "SELECT COUNT(*) FROM part")
        let eventCount   = try scalarInt(db, "SELECT COUNT(*) FROM event")

        return DiskUsage(
            dbFileSize: formatBytes(fileSize),
            sessionCount: sessionCount,
            messageCount: messageCount,
            partCount: partCount,
            eventCount: eventCount,
            dbSizeBytes: fileSize
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
        return String(format: "%.1f %@", value, units[unitIdx])
    }
}
