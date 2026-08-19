# 设计：磁盘用量统计加入 DSH 数据

日期：2026-08-19
状态：已确认（用户审阅通过）

## 背景

设置页「磁盘用量」区目前只统计 `opencode.db` + `deveco.db` 两个 SQLite 文件的大小
及各自 session/message/part/event 计数。DeepSeek Harness (DSH) 不是 SQLite 数据库，
而是 `~/.dsh/` 目录下的文件型数据，目前未纳入统计。

## DSH 数据格式（调研结论）

- `~/.dsh/sessions/**/session.jsonl.zstd`：每会话一个 zstd 压缩的 JSONL 日志（本机 26MB）
- `~/.dsh/storages/session_projcache.json` + `workspace.json`：JSON 投影缓存（140KB，会话元数据/token 用量）
- 其余 `profiles/`（128MB，web-ui 插件 node_modules）、`skills/`、`certs/` 等为安装/运行时数据，不算用量数据

## 决策（用户确认）

1. **统计范围**：仅 `sessions/` + `storages/`，不含 node_modules 等安装文件
2. **展示方式**：设置页新增独立的「DSH 数据」行组，与现有 opencode+deveco 行组并列

## 数据模型（`DiskUsage.swift`）

新增 5 个字段（现有 opencode+deveco 字段保持不动）：

```swift
struct DiskUsage: Codable {
    // 现有字段（opencode + deveco）
    let dbFileSize: String
    let sessionCount: Int
    let messageCount: Int
    let partCount: Int
    let eventCount: Int
    let dbSizeBytes: Int64

    // 新增 DSH 字段
    let dshFileSize: String
    let dshSizeBytes: Int64
    let dshSessionCount: Int
    let dshMessageCount: Int
    let dshEventCount: Int
}
```

## 采集逻辑（`DiskCleanupService.fetchDiskUsage()`）

- **大小**：递归求和 `~/.dsh/sessions/**/*` 全部文件大小 + `~/.dsh/storages/*` 两个 JSON 大小
  （沿用现有 `.size` 逻辑字节口径，与 opencode.db 一致）
- **会话数**：`sessions/` 下会话目录数（最廉价、不依赖 zstd）
- **消息数 / 事件数**：复用 `DshEventStore.shared.loadAll()`（增量缓存解析 JSONL，与统计页/小组件同源）；
  zstd 不可用时降级为 0 并展示「—」
- **容错**：`~/.dsh` 不存在 / sessions 或 storages 缺失时 DSH 数据整组为 0，不影响现有统计

## UI（`SettingsView.swift` DiskUsageDetailView）

在现有 4 行下方插入「DSH 数据」小标题 + 4 行：

```
数据库文件 …(现有)
会话记录   …
消息记录   …
事件日志   …

— DSH 数据 —
数据大小  26.14 MB
会话记录  N 条
消息记录  M 条
事件日志  K 条
```

## 影响面

- 仅改 3 个文件：`DiskUsage.swift`、`DiskCleanupService.swift`、`SettingsView.swift`
- 不改现有 opencode/deveco 逻辑；`dbFileSize`/`dbSizeBytes` 含义不变（DSH 单独字段，不合并）
- 清理按钮只作用于 opencode 数据库，与 DSH 无关，不触碰
