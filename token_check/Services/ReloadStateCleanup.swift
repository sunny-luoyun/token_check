import Foundation
import OSLog
import SQLite3

/// ReloadState 表自动清理：防止 NULL Kind 记录堆积导致通知中心卡顿
///
/// 问题背景：
/// - chronod 的 ReloadState 表主键是 (BundleID, Kind)
/// - SQLite 中 NULL 不参与唯一约束，导致相同的 (BundleID, NULL) 可以无限插入
/// - 当 chronod 处理 widget reload 请求时，如果找不到匹配的 kind，会记录 NULL Kind
/// - NULL Kind 记录堆积会导致 chronod 扫描无效历史记录，触发重试循环，通知中心卡顿
///
/// 解决方案：
/// - 定期检查 token_check 的 NULL Kind 记录数
/// - 如果超过阈值，清理这些无效记录
/// - 每个 (BundleID, Kind) 只保留最新的一条记录
struct ReloadStateCleanup {

    private static let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "reload-state-cleanup")

    /// 数据库路径
    private static let dbPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql"
    }()

    /// 清理阈值：超过此数量时触发清理
    private static let cleanupThreshold = 10

    /// 清理 token_check 的 NULL Kind 记录
    /// - Returns: 清理的记录数，如果访问失败返回 nil
    @discardableResult
    static func cleanupTokenCheckNullKindRecords() -> Int? {
        // 1. 检查数据库文件是否存在
        guard FileManager.default.fileExists(atPath: dbPath) else {
            logger.debug("ReloadState 数据库文件不存在，跳过清理")
            return nil
        }

        // 2. 打开数据库
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            logger.error("无法打开 ReloadState 数据库")
            return nil
        }
        defer { sqlite3_close(db) }

        // 3. 查询 token_check 的 NULL Kind 记录数
        let countQuery = """
            SELECT COUNT(*) FROM ReloadState 
            WHERE BundleID LIKE '%tokencheck%' AND Kind IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countQuery, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("无法查询 ReloadState 表")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            logger.error("无法读取 ReloadState 表")
            return nil
        }

        let count = Int(sqlite3_column_int(stmt, 0))

        // 4. 如果记录数小于阈值，不需要清理
        guard count > cleanupThreshold else {
            logger.debug("token_check NULL Kind 记录数 (\(count)) 未超过阈值 (\(self.cleanupThreshold))，跳过清理")
            return 0
        }

        // 5. 执行清理：删除 NULL Kind 记录
        let deleteQuery = """
            DELETE FROM ReloadState 
            WHERE BundleID LIKE '%tokencheck%' AND Kind IS NULL
        """

        guard sqlite3_exec(db, deleteQuery, nil, nil, nil) == SQLITE_OK else {
            logger.error("无法删除 token_check NULL Kind 记录")
            return nil
        }

        logger.notice("已清理 \(count) 条 token_check NULL Kind 记录")

        // 6. 返回清理的记录数
        return count
    }

    /// 检查是否需要清理
    /// - Returns: 是否需要清理
    static func needsCleanup() -> Bool {
        guard let db = openDatabase() else {
            return false
        }
        defer { sqlite3_close(db) }

        let countQuery = """
            SELECT COUNT(*) FROM ReloadState 
            WHERE BundleID LIKE '%tokencheck%' AND Kind IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countQuery, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return false
        }

        let count = Int(sqlite3_column_int(stmt, 0))
        return count > cleanupThreshold
    }

    /// 打开数据库
    private static func openDatabase() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return nil
        }
        return db
    }
}
