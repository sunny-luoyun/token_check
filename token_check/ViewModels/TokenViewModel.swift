import AppKit
import Combine
import Foundation
import OSLog
import WidgetKit

class TokenViewModel: ObservableObject {
    @Published var usage: TodayUsage?
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasRollback = false
    @Published var rollbackTotal: Int = 0
    @Published var adjustedInput: Int = 0
    @Published var adjustedOutput: Int = 0
    @Published var adjustedCacheRead: Int = 0
    @Published var adjustedReasoning: Int = 0
    @Published var adjustedCacheWrite: Int = 0
    @Published var adjustedTotal: Int = 0
    @Published var deepseekBalance: String?
    @Published var deepseekLoading = false

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "refresh")
    private let service = WidgetDataService()
    private var refreshTimer: Timer?
    private var healthCheckTimer: Timer?
    private var lastServerConnected: Bool?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var cachedMonthlyHeatmap: MonthlyHeatmapData?
    private var cachedYearlyHeatmap: YearlyHeatmapData?
    private var lastRefreshTotalTokens: Int = -1
    private var lastRefreshSessionCount: Int = 0
    private var forceFullRefreshCount: Int = 0
    private var lastRefreshInterval: TimeInterval = 0
    private var lastApiKey: String = ""
    /// 健康检查防重入标志：仅主线程读写（Timer 回调与 Task 完成回调均在主线程）
    private var isHealthCheckInFlight = false
    private let widgetDataQueue = DispatchQueue(label: "com.luoyun.tokencheck.widget-data", qos: .utility)
    /// ReloadState 清理计数器：每 N 次 refresh 后检查一次
    private var reloadStateCleanupCounter = 0
    private let reloadStateCleanupInterval = 10

    init() {
        // 启动时清理 ReloadState 表中的 NULL Kind 记录，防止通知中心卡顿
        ReloadStateCleanup.cleanupTokenCheckNullKindRecords()

        setupPeriodicRefresh()
        setupHealthCheck()
        setupWakeNotification()
        setupSettingsObserver()
        refresh(showLoading: false)
    }

    deinit {
        refreshTimer?.invalidate()
        healthCheckTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func setupPeriodicRefresh() {
        refreshTimer?.invalidate()
        let interval = Self.readRefreshInterval()
        let now = Date()
        let secs = now.timeIntervalSince1970
        let fireDate = Date(timeIntervalSince1970: (floor(secs / interval) + 1) * interval)

        let timer = Timer(fire: fireDate, interval: interval, repeats: true) { [weak self] _ in
            self?.refresh(showLoading: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        logger.notice("refreshTimer 已设置: interval=\(Int(interval), privacy: .public)s, fireDate=\(ISO8601DateFormatter().string(from: fireDate), privacy: .public)")
        reloadWidgetTimelines()
    }

    private func setupWakeNotification() {
        wakeObserver = NSWorkspace.shared.notificationCenter
            .addObserver(forName: NSNotification.Name("NSWorkspaceWillWakeNotification"),
                         object: nil, queue: .main) { [weak self] _ in
                self?.refresh(showLoading: false)
            }
    }

    private func setupSettingsObserver() {
        lastRefreshInterval = Self.readRefreshInterval()
        lastApiKey = UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: "opencodeApiKey") ?? ""
        settingsObserver = NotificationCenter.default
            .addObserver(forName: UserDefaults.didChangeNotification,
                         object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let newInterval = Self.readRefreshInterval()
                if newInterval != self.lastRefreshInterval {
                    self.lastRefreshInterval = newInterval
                    self.setupPeriodicRefresh()
                    self.refresh(showLoading: false)
                }
                // API Key 变化时也触发刷新
                let currentKey = UserDefaults(suiteName: "group.com.luoyun.tokencheck")?.string(forKey: "opencodeApiKey") ?? ""
                if currentKey != self.lastApiKey {
                    self.lastApiKey = currentKey
                    self.logger.notice("OpenCode API Key 变化，刷新订阅数据")
                    self.refresh(showLoading: false)
                }
            }
    }

    private func setupHealthCheck() {
        let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck")
        lastServerConnected = defaults?.bool(forKey: "server_connected")
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkServerHealth()
        }
    }

    /// 健康检查改为 async：不再阻塞主线程（原 Timer 每 5s 在主线程同步等待网络最多 3s）。
    /// 用 isHealthCheckInFlight 防重入——async 后请求周期可能超过 5s 的 Timer 间隔。
    private func checkServerHealth() {
        guard !isHealthCheckInFlight else { return }
        isHealthCheckInFlight = true
        Task { [weak self] in
            let connected = await self?.service.checkCloudHealth() ?? false
            DispatchQueue.main.async {
                self?.writeServerHealth(connected)
                self?.isHealthCheckInFlight = false
            }
        }
    }

    private func writeServerHealth(_ connected: Bool) {
        guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else { return }
        defaults.set(connected, forKey: "server_connected")
        if connected != lastServerConnected {
            lastServerConnected = connected
            logger.notice("opencode 服务器状态变化: \(connected ? "已连接" : "已断开", privacy: .public)，立即刷新 widget")
            reloadWidgetTimelines()
        }
    }

    /// 检查当前时间是否接近对齐刷新时间（±threshold 秒内）
    private func isNearAlignedRefreshTime(threshold: TimeInterval = 30) -> Bool {
        let interval = Self.readRefreshInterval()
        let now = Date()
        let seconds = now.timeIntervalSince1970
        let nextAligned = (floor(seconds / interval) + 1) * interval
        let prevAligned = floor(seconds / interval) * interval
        // 接近下一个对齐时间，或刚过上一个对齐时间
        return (nextAligned - seconds) <= threshold || (seconds - prevAligned) <= threshold
    }

    private func reloadWidgetTimelines() {
        // 对齐时间守卫：只在接近对齐刷新点时才真正通知 WidgetKit reload，
        // 其他时间 app 端只更新数据文件，小组件自带的 .after 时间线策略
        // 会在对齐时间自动触发 getTimeline 并读取最新数据。
        // 这避免了 app 旁路触发导致小组件在非预期时间刷新（如设置5分钟间隔，
        // 却在第2、7分钟也出现更新）。
        guard isNearAlignedRefreshTime() else {
            logger.notice("非对齐时间，跳过 WidgetKit reload（数据文件已更新，等对齐时间自动刷新）")
            return
        }
        let kinds = liveWidgetKinds()
        let skipped = Self.allWidgetKinds.filter { !kinds.contains($0) }
        if !skipped.isEmpty {
            logger.notice("跳过无存活实例的 widget kind（幽灵实例防护）: \(skipped.joined(separator: ", "), privacy: .public)")
        }
        let step = 0.3
        DispatchQueue.main.async {
            for (index, kind) in kinds.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * step) {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            }
        }
    }

    /// 所有已注册的 widget kind（与 token_checkWidget 中各 Widget.kind 一一对应）
    private static let allWidgetKinds = [
        "TokenCheckLargeWidgetV3",
        "TokenCheckSmallWidgetV2",
        "ClashTrafficWidget"
    ]

    /// 幽灵实例防护：只返回仍有存活实例的 widget kind。
    ///
    /// 判断依据：存活实例的 timeline 文件会随每次数据变化被 chronod 重写；
    /// 已从通知中心/桌面移除的幽灵实例，其 chrono/timelines/<kind>/ 下的文件
    /// 会永久冻结。对幽灵 kind 调用 reloadTimelines 会触发 chronod
    /// "No matching descriptor" 重试与 pendingTasks 堆积，导致通知中心卡顿
    /// 10 秒以上（见 AGENTS.md 卡顿排查记录）。
    ///
    /// 回退策略：读不到 chrono 容器时返回全部 kind（保持原行为）；
    /// kind 目录不存在（从未实例化）时跳过；目录存在但文件超过 24 小时未
    /// 更新时跳过（小组件自带 .after 时间线策略，存活实例恢复数据变化后
    /// 文件会自动变新，跳过只是暂时少一次主动刷新）。
    private func liveWidgetKinds(now: Date = Date()) -> [String] {
        let timelinesRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.luoyun.tokencheck.widget/Data/SystemData/com.apple.chrono/timelines")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: timelinesRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return Self.allWidgetKinds
        }
        let cutoff = now.addingTimeInterval(-24 * 3600)
        return Self.allWidgetKinds.filter { kind in
            let dir = timelinesRoot.appendingPathComponent(kind)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ), !files.isEmpty else {
                return false
            }
            return files.contains { file in
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (mtime ?? .distantPast) > cutoff
            }
        }
    }

    static func readRefreshInterval() -> TimeInterval {
        guard let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") else {
            return 60
        }
        let seconds = defaults.integer(forKey: "widgetRefreshInterval")
        return max(60, seconds == 0 ? 60 : TimeInterval(seconds))
    }

    func refresh(showLoading: Bool = true) {
        let apiKey = UserDefaults.standard.string(forKey: "deepseekApiKey") ?? ""
        if showLoading {
            isLoading = true
            deepseekLoading = !apiKey.isEmpty
        }
        error = nil
        DatabaseService.loadQueue.addOperation { [weak self] in
            guard let self else { return }
            var t0 = CFAbsoluteTimeGetCurrent()
            if let ds = DatabaseService.shared, let db = ds.db {
                TokenDeltaTracker.shared.refresh(db: db)
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            self.logger.notice("TokenDeltaTracker: \(String(format: "%.1f", (t1 - t0) * 1000), privacy: .public)ms")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let todayKey = df.string(from: Date())
            let todayDCon = TokenDeltaTracker.shared.dailyConsumption[todayKey]
            let todayDConTotal = todayDCon?.total ?? 0
            let todayDConSessions = TokenDeltaTracker.shared.dailyModelConsumption[todayKey]?.count ?? 0
            self.logger.notice("dailyConsumption today: total=\(todayDConTotal, privacy: .public), models=\(todayDConSessions, privacy: .public)")
            let todayRb = TokenDeltaTracker.shared.dailyRollbacks[todayKey] ?? .zero
            let hasRb = todayRb.total > 0
            let result = service.fetchTodayUsage()
            let t2 = CFAbsoluteTimeGetCurrent()
            self.logger.notice("fetchTodayUsage: \(String(format: "%.1f", (t2 - t1) * 1000), privacy: .public)ms")

            if !apiKey.isEmpty {
                Task {
                    let balance = await DeepSeekBalanceService.shared.fetchBalance(apiKey: apiKey)
                    await MainActor.run {
                        self.deepseekBalance = balance
                        self.deepseekLoading = false
                    }
                }
            }

            let adjInput = result.map { $0.inputTokens + todayRb.rolledBackInput } ?? 0
            let adjOutput = result.map { $0.outputTokens + todayRb.rolledBackOutput } ?? 0
            let adjCacheRead = result.map { $0.cacheReadTokens + todayRb.rolledBackCacheRead } ?? 0
            let adjReasoning = result.map { $0.reasoningTokens + todayRb.rolledBackReasoning } ?? 0
            let adjCacheWrite = result.map { $0.cacheWriteTokens + todayRb.rolledBackCacheWrite } ?? 0
            let adjTotal = result.map { $0.totalTokens + todayRb.total } ?? 0

            // 主线程只更新 UI，不涉及任何跨进程调用
            DispatchQueue.main.async {
                self.hasRollback = hasRb
                self.rollbackTotal = todayRb.total
                self.adjustedInput = adjInput
                self.adjustedOutput = adjOutput
                self.adjustedCacheRead = adjCacheRead
                self.adjustedReasoning = adjReasoning
                self.adjustedCacheWrite = adjCacheWrite
                self.adjustedTotal = adjTotal
                if let result {
                    self.usage = result
                } else {
                    self.error = DatabaseService.initError?.localizedDescription ?? "无法读取数据库"
                }
                self.isLoading = false
                if apiKey.isEmpty {
                    self.deepseekBalance = nil
                    self.deepseekLoading = false
                }
            }

            // 写入 widget_data.json（由定时器控制频率，不额外触发 WidgetKit 重载）
            guard let result else {
                self.logger.notice("Total refresh: no data, skipped")
                return
            }

            let subscriptionData = self.service.computeSubscriptionData()
            if let sd = subscriptionData {
                self.logger.notice("订阅: used=\(String(format: "%.2f", sd.used)), budget=\(String(format: "%.2f", sd.budget)), remaining=\(String(format: "%.2f", sd.remaining)), pct=\(String(format: "%.0f", sd.used / sd.budget * 100))%")
            } else {
                self.logger.notice("订阅: 未启用或数据异常")
            }

            let widgetUsage = TodayUsage(
                totalTokens: adjTotal,
                inputTokens: adjInput,
                outputTokens: adjOutput,
                cacheReadTokens: adjCacheRead,
                reasoningTokens: adjReasoning,
                cacheWriteTokens: adjCacheWrite,
                sessionCount: result.sessionCount,
                messageCount: result.messageCount,
                projectCount: result.projectCount,
                additions: result.additions,
                deletions: result.deletions,
                files: result.files,
                dailyTokens: result.dailyTokens,
                hourlyTokens: result.hourlyTokens,
                todayCost: result.todayCost,
                subscriptionRemaining: subscriptionData?.remaining,
                subscriptionBudget: subscriptionData?.budget,
                subscriptionUsed: subscriptionData?.used,
                subscriptionPeriodEnd: subscriptionData?.periodEnd,
                subscriptionEnabled: subscriptionData != nil
            )

            // 判断数据是否变化：对比总 token 数和 session 数，每 5 次强制完整刷新一次
            let dataChanged = adjTotal != self.lastRefreshTotalTokens
                || result.sessionCount != self.lastRefreshSessionCount
                || self.forceFullRefreshCount >= 5

            if dataChanged {
                self.logger.notice("数据已变化(oldTotal=\(self.lastRefreshTotalTokens, privacy: .public), newTotal=\(adjTotal, privacy: .public)), 重新计算热力图")
                let mm = self.service.fetchMonthData()
                let yy = self.service.fetchYearlyData()
                let mmDesc = mm.map { "\($0.month)-\($0.totalTokens)" } ?? "nil"
                let yyDesc = yy.map { "\($0.year)-\($0.totalTokens)" } ?? "nil"
                self.logger.notice("热力图计算完成: month=\(mmDesc, privacy: .public), year=\(yyDesc, privacy: .public)")
                self.cachedMonthlyHeatmap = mm
                self.cachedYearlyHeatmap = yy
                self.lastRefreshTotalTokens = adjTotal
                self.lastRefreshSessionCount = result.sessionCount
                self.forceFullRefreshCount = 0
            } else {
                self.forceFullRefreshCount += 1
                let remaining = 5 - self.forceFullRefreshCount
                self.logger.notice("数据未变化(total=\(adjTotal, privacy: .public)), 使用缓存热力图, 距强制刷新还有 \(remaining, privacy: .public) 次")
            }

            let combined = CombinedWidgetData(
                todayUsage: widgetUsage,
                monthlyHeatmap: self.cachedMonthlyHeatmap,
                yearlyHeatmap: self.cachedYearlyHeatmap
            )

            // 在后台队列执行文件写入 + Widget 刷新，不阻塞 loadQueue
            widgetDataQueue.async {
                guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") else {
                    self.logger.notice("widget container 获取失败")
                    return
                }

                // DSH 版 widget 数据（小组件数据源切到 DSH/总 时使用；每次刷新都写，保证及时）
                if let dshWidgetData = DshWidgetDataService.shared.fetchWidgetData(),
                   let dshEncoded = try? JSONEncoder().encode(dshWidgetData) {
                    let dshURL = container.appendingPathComponent("dsh_widget_data.json")
                    try? dshEncoded.write(to: dshURL, options: .atomic)
                    self.logger.notice("dsh widget 文件写入完成")
                }

                guard let encoded = try? JSONEncoder().encode(combined) else {
                    self.logger.notice("widget data 编码失败")
                    return
                }
                let url = container.appendingPathComponent("widget_data.json")
                if let existing = try? Data(contentsOf: url), existing == encoded {
                    self.logger.notice("widget 数据与文件一致, 跳过写入和刷新")
                    return
                }
                let writeStart = CFAbsoluteTimeGetCurrent()
                try? encoded.write(to: url, options: .atomic)
                self.logger.notice("widget 文件写入完成 (\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - writeStart) * 1000), privacy: .public)ms)")
                self.reloadWidgetTimelines()

                // 定时清理 ReloadState 表中的 NULL Kind 记录，防止通知中心卡顿
                self.reloadStateCleanupCounter += 1
                if self.reloadStateCleanupCounter >= self.reloadStateCleanupInterval {
                    self.reloadStateCleanupCounter = 0
                    ReloadStateCleanup.cleanupTokenCheckNullKindRecords()
                }

                // Clash 流量拉取改独立 Task（async），不阻塞 widgetDataQueue
                let clashService = ClashTrafficService()
                Task {
                    let clashOK = await clashService.fetchAndWriteTrafficData()
                    if clashOK {
                        self.logger.notice("Clash 流量数据已更新")
                    } else {
                        self.logger.notice("Clash 流量更新失败（订阅地址不可达）")
                    }
                }
            }
            let totalElapsed = CFAbsoluteTimeGetCurrent() - t0
            self.logger.notice("Total refresh: \(String(format: "%.1f", totalElapsed * 1000), privacy: .public)ms")
        }
    }
}
