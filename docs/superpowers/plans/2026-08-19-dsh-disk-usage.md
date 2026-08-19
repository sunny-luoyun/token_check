# DSH 磁盘用量统计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设置页「磁盘用量」区新增独立的「DSH 数据」行组，统计 `~/.dsh/sessions/` + `~/.dsh/storages/` 的大小与会话/消息/事件计数。

**Architecture:** `DiskCleanupService.fetchDiskUsage()` 在现有 opencode+deveco 统计之外，递归求和 DSH sessions/storages 目录文件大小、按会话目录数计会话数、复用 `DshEventStore.shared.loadAll()` 得消息/事件数；`DiskUsage` 结构体新增 5 个 DSH 字段；`SettingsView` 的 `DiskUsageDetailView` 在现有 4 行下插入独立 DSH 行组。

**Tech Stack:** Swift 5 / SwiftUI / SQLite3 / Foundation。项目无测试 target，验证方式沿用仓库惯例：临时脚本 + `xcodebuild` 编译（见 2026-08-13-time-window-independent-price.md）。

## Global Constraints

- 只统计 `~/.dsh/sessions/**` 全部文件 + `~/.dsh/storages/*` 两个 JSON（**不含** `profiles/` node_modules、`skills/`、`certs/` 等安装/运行时数据）
- DSH 主目录解析复用 `DshService.dshHomePath`（优先 `$DSH_HOME`，否则 `~/.dsh`），不新建路径逻辑
- `DiskUsage` 现有字段（dbFileSize/dbSizeBytes/sessionCount/messageCount/partCount/eventCount）含义与数值**不变**，DSH 用独立字段
- `~/.dsh` 不存在 / sessions 或 storages 缺失时，DSH 各计数为 0，不抛错、不影响现有统计
- zstd 不可用时消息/事件数为 0，UI 展示「—」；会话数（目录计数）不依赖 zstd
- 不触碰清理按钮逻辑（只作用于 opencode 数据库）
- 中文 UI 文案

---

### Task 1: `DiskUsage` 模型新增 DSH 字段

**Files:**
- Modify: `token_check/Models/DiskUsage.swift`（整文件替换）

**Interfaces:**
- Consumes: 无
- Produces: `DiskUsage` 新增字段 `dshFileSize: String`、`dshSizeBytes: Int64`、`dshSessionCount: Int`、`dshMessageCount: Int`、`dshEventCount: Int`。Task 2 构造、Task 3 消费。

- [ ] **Step 1: 改写模型**

`token_check/Models/DiskUsage.swift` 全文替换为：

```swift
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
```

- [ ] **Step 2: 编译验证**

Run: `cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/derived build 2>&1 | tail -5`

注意：此时 `DiskCleanupService` 构造 `DiskUsage` 少 5 个参数会编译失败——**这是预期的中间态**，等 Task 2 补齐构造参数后通过。若想本任务自验通过，可改为仅查看模型文件语法（`swiftc -parse token_check/Models/DiskUsage.swift`，无输出即通过）。

Expected: `swiftc -parse` 无输出、退出码 0。

- [ ] **Step 3: Commit**

```bash
git add token_check/Models/DiskUsage.swift
git commit -m "feat: DiskUsage 模型新增 DSH 数据字段"
```

---

### Task 2: `DiskCleanupService` 采集 DSH 大小与会话/消息/事件计数

**Files:**
- Modify: `token_check/Services/DiskCleanupService.swift`（全文替换）

**Interfaces:**
- Consumes:
  - `AppDatabase.opencodePath` / `AppDatabase.devecoPath`（现有，不动）
  - `DshService.dshHomePath`（`DshService.swift:28`，已有）
  - `DshEventStore.shared.loadAll()`（`DshEventStore.swift:38`，返回 `[String: (header:, events:, userMessages:, assistantMessages:)]`）
  - Task 1 的 `DiskUsage` 5 个新字段
- Produces: `fetchDiskUsage() throws -> DiskUsage` 现在带完整 DSH 数据。Task 3 消费。

- [ ] **Step 1: 改写服务**

`token_check/Services/DiskCleanupService.swift` 全文替换为：

```swift
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
```

- [ ] **Step 2: 编译验证**

Run: `cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/derived build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 临时脚本验证计数口径（与真实 ~/.dsh 对比）**

创建 `/var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/dshdu/main.swift`（不入库），内容：

```swift
import Foundation

let home = NSString(string: NSHomeDirectory()).appendingPathComponent(".dsh")
let fm = FileManager.default

func dirSize(_ dir: URL) -> Int64 {
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for case let u as URL in en {
        if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
    }
    return total
}

func countDirs(_ dir: URL) -> Int {
    guard let c = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
    return c.filter { var d: ObjCBool = false; fm.fileExists(atPath: $0.path, isDirectory: &d); return d.boolValue }.count
}

let sessions = URL(fileURLWithPath: home).appendingPathComponent("sessions")
let storages = URL(fileURLWithPath: home).appendingPathComponent("storages")
let size = dirSize(sessions) + dirSize(storages)
print("sizeBytes=\(size) (\(Double(size)/1024/1024, specifier: "%.2f") MB)")
print("sessionDirs=\(countDirs(sessions))")
print("storagesExists=\(fm.fileExists(atPath: storages.path))")
```

Run:
```bash
mkdir -p /var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/dshdu && \
swift /var/folders/v5/6gcpn2g540l5b_7g2bnj4w_00000gn/T/opencode/dshdu/main.swift
```

Expected：`sizeBytes` 与 `du -sh ~/.dsh/sessions ~/.dsh/storages` 合计一致（约 26.1 MB）；`sessionDirs` 与 `find ~/.dsh/sessions -mindepth 1 -maxdepth 1 -type d | wc -l` 一致（本机 6）。

- [ ] **Step 4: Commit**

```bash
git add token_check/Services/DiskCleanupService.swift
git commit -m "feat: 磁盘用量统计采集 DSH sessions/storages 大小与会话消息事件计数"
```

---

### Task 3: 设置页新增「DSH 数据」行组

**Files:**
- Modify: `token_check/Views/SettingsView.swift:1113-1127`（`DiskUsageDetailView`）

**Interfaces:**
- Consumes: Task 1/2 的 `DiskUsage.dshFileSize/dshSessionCount/dshMessageCount/dshEventCount`
- Produces: 设置页「磁盘用量」区新增 DSH 行组（UI 变更，无下游依赖）

- [ ] **Step 1: 改写 DiskUsageDetailView**

将 `SettingsView.swift` 第 1113-1127 行的 `DiskUsageDetailView` 替换为：

```swift
// MARK: - 磁盘用量子视图

private struct DiskUsageDetailView: View {
    let usage: DiskUsage

    var body: some View {
        VStack(spacing: 8) {
            DiskUsageRow(icon: "externaldrive.fill", label: "数据库文件", value: usage.dbFileSize)
            DiskUsageRow(icon: "rectangle.stack.fill", label: "会话记录",   value: "\(usage.sessionCount) 条")
            DiskUsageRow(icon: "text.bubble.fill",     label: "消息记录",   value: "\(usage.messageCount) 条")
            DiskUsageRow(icon: "doc.text.fill",        label: "事件日志",   value: "\(usage.eventCount) 条")

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("DSH 数据")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            DiskUsageRow(icon: "externaldrive.fill", label: "数据大小", value: usage.dshFileSize)
            DiskUsageRow(icon: "rectangle.stack.fill", label: "会话记录", value: dshSessionText)
            DiskUsageRow(icon: "text.bubble.fill",     label: "消息记录", value: dshMessageText)
            DiskUsageRow(icon: "doc.text.fill",        label: "事件日志", value: dshEventText)
        }
        .padding(.vertical, 4)
    }

    /// zstd 不可用/无数据时展示「—」
    private var dshSessionText: String { "\(usage.dshSessionCount) 条" }
    private var dshMessageText: String {
        usage.dshMessageCount > 0 ? "\(usage.dshMessageCount) 条" : "—"
    }
    private var dshEventText: String {
        usage.dshEventCount > 0 ? "\(usage.dshEventCount) 条" : "—"
    }
}

private struct DiskUsageRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd /Users/langqin/macapp/token_check && xcodebuild -project token_check.xcodeproj -scheme token_check -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/derived build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add token_check/Views/SettingsView.swift
git commit -m "feat: 设置页磁盘用量新增 DSH 数据行组"
```

---

### Task 4: 端到端验证

**Files:** 无

- [ ] **Step 1: 运行 app 目视验证**

Run: `open /Users/langqin/macapp/token_check/.build/derived/Build/Products/Debug/token_check.app`

打开「设置」→ 拉到「磁盘用量」区，确认：
1. 现有 4 行（数据库文件/会话记录/消息记录/事件日志）数值与改动前一致
2. 下方出现分隔线 +「DSH 数据」小标题
3. DSH 数据大小 ≈ 26.1 MB，会话记录 ≈ 6 条，消息/事件为具体数字（zstd 可用）或「—」（不可用）

- [ ] **Step 2: 最终 git 状态确认**

Run: `git status --short && git log --oneline -4`

Expected：工作区干净（仅未跟踪的 `.build/derived` 除外，若 `.gitignore` 未覆盖可加入）；最近 4 条 commit 含本次 3 个 feat。
