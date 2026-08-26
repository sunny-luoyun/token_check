import Foundation
import OSLog

/// DSH 会话事件存储（L2）：解析 ~/.dsh/sessions 下的 JSONL 日志（zstd 压缩或明文），
/// 提取每次 LLM 调用的 usage 记账（assistant/message 的 data.usage + message.source）。
///
/// 增量策略：按文件 (size, mtime) 判断变化，未变化的会话跳过重新解析；
/// 解析结果缓存在内存，聚合层每次从缓存重建（毫秒级）。
///
/// 注意：解压必须「先读管道、再 waitUntilExit」——zstd 输出超过管道缓冲(64KB)时，
/// 先 wait 会与子进程互相等待造成死锁（子进程写满缓冲阻塞，父进程死等退出）。
final class DshEventStore {
    static let shared = DshEventStore()

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "dsh-events")
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var zstdPath: String?

    struct FileStamp: Equatable, Codable {
        let size: UInt64
        let mtime: TimeInterval
    }

    /// 磁盘缓存条目：stamp 未变化的会话直接反序列化复用，避免每次冷启动重新 spawn zstd
    /// （134 个文件逐个 fork/exec + Pipe 实测 14 秒/次，是 loadDetailedData 5-6s 的真凶）
    private struct CachedEntry: Codable {
        let stamp: FileStamp
        let header: DshLogHeader?
        let events: [DshUsageEvent]
        let userMessageCount: Int
        let assistantMessageCount: Int
    }

    private struct Entry {
        /// 会话目录名（session-<id>），稳定且不依赖日志内容
        let dirName: String
        let stamp: FileStamp
        let header: DshLogHeader?
        let events: [DshUsageEvent]
        /// user/message 事件数（会话级，供 widget 消息指标）
        let userMessageCount: Int
        /// assistant/message 事件数（会话级）
        let assistantMessageCount: Int
    }

    /// 全量读取（增量：未变化文件跳过）。返回 sessionID -> (header, usageEvents, 消息计数)
    func loadAll() -> [String: (header: DshLogHeader?, events: [DshUsageEvent], userMessages: Int, assistantMessages: Int)] {
        guard let home = DshService.dshHomePath else { return [:] }
        let sessionsDir = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var updated: [String: Entry] = [:]
        var touchedFiles = 0

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name == "session.jsonl.zstd" || name == "session.jsonl" else { continue }

            // 目录名（session-<uuid>）作为缓存 key：解析前即可确定，不依赖日志内容
            let dirName = url.deletingLastPathComponent().lastPathComponent
            guard let stamp = stamp(of: url) else { continue }

            lock.lock()
            let cached = cache[dirName]
            lock.unlock()

            if let cached, cached.stamp == stamp {
                updated[dirName] = cached
                continue
            }

            if let diskCached = loadDiskEntry(dirName: dirName), diskCached.stamp == stamp {
                let entry = Entry(
                    dirName: dirName,
                    stamp: stamp,
                    header: diskCached.header,
                    events: diskCached.events,
                    userMessageCount: diskCached.userMessageCount,
                    assistantMessageCount: diskCached.assistantMessageCount
                )
                updated[dirName] = entry
                continue
            }

            touchedFiles += 1
            if let parsed = parseLog(url: url, dirName: dirName, stamp: stamp) {
                updated[dirName] = parsed
            }
        }

        lock.lock()
        cache = updated
        lock.unlock()

        // 有文件被重新解析时持久化磁盘缓存（正常无变化时零开销）
        if touchedFiles > 0 {
            saveDiskEntries(updated)
        }

        // 返回时用 header.id（缺失时用目录名去前缀兜底）
        var result: [String: (header: DshLogHeader?, events: [DshUsageEvent], userMessages: Int, assistantMessages: Int)] = [:]
        for entry in updated.values {
            let id = entry.header?.id
                ?? (entry.dirName.hasPrefix("session-") ? String(entry.dirName.dropFirst("session-".count)) : entry.dirName)
            result[id] = (entry.header, entry.events, entry.userMessageCount, entry.assistantMessageCount)
        }
        return result
    }

    private func parseLog(url: URL, dirName: String, stamp: FileStamp) -> Entry? {
        guard let text = decompressedText(url: url) else { return nil }

        // 会话 id：header.id 优先，缺失时用目录名（事件归属需要）
        let fallbackID = dirName.hasPrefix("session-") ? String(dirName.dropFirst("session-".count)) : dirName
        var sessionID = fallbackID

        var header: DshLogHeader?
        var events: [DshUsageEvent] = []
        var userMessageCount = 0
        var assistantMessageCount = 0
        // (turn, step) -> usage，用于 assistant/message 缺 usage 时兜底（usage chunk 先于 message 到达）
        var chunkUsage: [String: [String: Any]] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // 廉价预过滤：先扫描 "type" 字段值，仅目标类型才做完整 JSON 解析
            // （日志中绝大多数行是消息内容，逐行 JSONSerialization 是 loadAll 冷启动 5.9s 的主要耗时）
            guard let typeValue = extractType(from: String(rawLine)) else { continue }

            let type: String
            switch typeValue {
            case "session", "user/message", "assistant/message", "assistant/chunk":
                type = typeValue
            default:
                continue
            }

            guard let obj = try? JSONSerialization.jsonObject(with: Data(String(rawLine).utf8)) as? [String: Any] else { continue }

            switch type {
            case "session":
                header = makeHeader(obj, sessionID: fallbackID)
                if let id = obj["id"] as? String, !id.isEmpty {
                    sessionID = id
                }

            case "user/message":
                userMessageCount += 1

            case "assistant/message":
                assistantMessageCount += 1
                guard let data = obj["data"] as? [String: Any],
                      let turn = data["turn"] as? Int,
                      let step = data["step"] as? Int else { continue }
                let key = "\(turn)/\(step)"
                let usage = (data["usage"] as? [String: Any]) ?? chunkUsage[key]
                guard let usage else { continue }
                let source = (data["message"] as? [String: Any])?["source"] as? [String: Any]
                // 仅 model 来源计入（避开用户/系统注入的消息）
                guard (source?["kind"] as? String) == "model" else { continue }
                let time = (obj["time"] as? NSNumber)?.doubleValue ?? 0
                let provider = source?["provider"] as? String
                let model = source?["model"] as? String
                guard let provider, let model, !model.isEmpty else { continue }
                events.append(DshUsageEvent(
                    sessionID: sessionID,
                    seq: (obj["seq"] as? NSNumber)?.intValue ?? 0,
                    time: Date(timeIntervalSince1970: time / 1000),
                    turn: turn,
                    step: step,
                    inputTokens: int(usage, "inputTokens"),
                    outputTokens: int(usage, "outputTokens"),
                    cacheReadTokens: int(usage, "cacheReadTokens"),
                    cacheWriteTokens: int(usage, "cacheWriteTokens"),
                    reasoningTokens: int(usage, "reasoningTokens"),
                    providerID: provider,
                    modelId: model
                ))

            case "assistant/chunk":
                // usage chunk：流式记账，message 缺 usage 时兜底（同一 turn/step 不重复计）
                guard let data = obj["data"] as? [String: Any],
                      let chunk = data["chunk"] as? [String: Any],
                      (chunk["type"] as? String) == "usage",
                      let usage = chunk["usage"] as? [String: Any],
                      let turn = data["turn"] as? Int,
                      let step = data["step"] as? Int else { continue }
                chunkUsage["\(turn)/\(step)"] = usage

            default:
                break
            }
        }

        guard !events.isEmpty || header != nil else { return nil }
        return Entry(
            dirName: dirName,
            stamp: stamp,
            header: header,
            events: events,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount
        )
    }

    private func makeHeader(_ obj: [String: Any], sessionID: String) -> DshLogHeader {
        DshLogHeader(
            id: obj["id"] as? String ?? sessionID,
            createdAt: Date(timeIntervalSince1970: ((obj["createdAt"] as? NSNumber)?.doubleValue ?? 0) / 1000),
            cwd: obj["cwd"] as? String ?? "",
            agentPreset: obj["agentPreset"] as? String,
            parentSession: obj["parentSession"] as? String,
            delegationDepth: (obj["delegationDepth"] as? NSNumber)?.intValue
        )
    }

    private func int(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }

    /// 从单行 JSON 中廉价提取 type 字段值（不做完整 JSON 解析）。
    /// 期望格式 `"type":"xxx"`（无空白）或 `"type": "xxx"`；找不到返回 nil。
    private func extractType(from line: String) -> String? {
        guard let range = line.range(of: "\"type\":") ?? line.range(of: "\"type\": ") else { return nil }
        var value = line[range.upperBound...]
        value = value.drop { $0.isWhitespace }
        guard value.first == "\"" else { return nil }
        value = value.dropFirst()
        var type = ""
        for ch in value {
            if ch == "\"" { break }
            type.append(ch)
            if type.count > 64 { break }
        }
        return type.isEmpty ? nil : type
    }

    // MARK: - 解压

    /// 用 zstd CLI 解压日志（明文 .jsonl 直接读）。
    /// 必须先 readDataToEndOfFile 再 waitUntilExit，否则大输出会死锁。
    private func decompressedText(url: URL) -> String? {
        if url.pathExtension == "jsonl" {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        guard let zstd = resolveZstd() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr 重定向到 /dev/null，避免无人读取的 stderr 管道阻塞子进程
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("zstd 启动失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // 关键顺序：先读完全部输出（读到 EOF），再等待退出
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("zstd 解压失败: \(url.path, privacy: .public) status=\(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 探测 zstd 可执行文件（Homebrew / 系统路径 / PATH）
    private func resolveZstd() -> String? {
        if let zstdPath { return zstdPath }
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
            "/bin/zstd"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            zstdPath = candidate
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/zstd"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    zstdPath = candidate
                    return candidate
                }
            }
        }
        logger.warning("未找到 zstd 可执行文件，DSH 统计回退到投影缓存（L1）")
        return nil
    }

    private func stamp(of url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileStamp(size: UInt64(size), mtime: mtime)
    }

    // MARK: - 磁盘缓存

    private static let diskCacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("dsh_events_cache.plist")
    }()

    private func loadDiskEntries() -> [String: CachedEntry] {
        guard let data = try? Data(contentsOf: Self.diskCacheURL),
              let entries = try? PropertyListDecoder().decode([String: CachedEntry].self, from: data) else {
            return [:]
        }
        return entries
    }

    private var diskCache: [String: CachedEntry]?

    private func loadDiskEntry(dirName: String) -> CachedEntry? {
        lock.lock()
        defer { lock.unlock() }
        if diskCache == nil {
            diskCache = loadDiskEntries()
        }
        return diskCache?[dirName]
    }

    private func saveDiskEntries(_ entries: [String: Entry]) {
        lock.lock()
        defer { lock.unlock() }
        var cache = diskCache ?? loadDiskEntries()
        for entry in entries.values {
            cache[entry.dirName] = CachedEntry(
                stamp: entry.stamp,
                header: entry.header,
                events: entry.events,
                userMessageCount: entry.userMessageCount,
                assistantMessageCount: entry.assistantMessageCount
            )
        }
        diskCache = cache
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(cache)
            try data.write(to: Self.diskCacheURL, options: .atomic)
        } catch {
            logger.error("DSH 事件磁盘缓存写入失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
