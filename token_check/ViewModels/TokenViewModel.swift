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
    private var wakeObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    init() {
        setupPeriodicRefresh()
        setupWakeNotification()
        setupSettingsObserver()
        refresh(showLoading: false)
    }

    deinit {
        refreshTimer?.invalidate()
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

        let fireDate: Date
        if interval > 60 {
            let secs = now.timeIntervalSince1970
            fireDate = Date(timeIntervalSince1970: (floor(secs / interval) + 1) * interval)
        } else {
            fireDate = now.addingTimeInterval(interval)
        }

        let timer = Timer(fire: fireDate, interval: interval, repeats: true) { [weak self] _ in
            self?.refresh(showLoading: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func setupWakeNotification() {
        wakeObserver = NSWorkspace.shared.notificationCenter
            .addObserver(forName: NSNotification.Name("NSWorkspaceWillWakeNotification"),
                         object: nil, queue: .main) { [weak self] _ in
                self?.refresh(showLoading: false)
            }
    }

    private func setupSettingsObserver() {
        settingsObserver = NotificationCenter.default
            .addObserver(forName: UserDefaults.didChangeNotification,
                         object: nil, queue: .main) { [weak self] _ in
                self?.setupPeriodicRefresh()
            }
    }

    static func readRefreshInterval() -> TimeInterval {
        let seconds = UserDefaults.standard.integer(forKey: "widgetRefreshInterval")
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
            self.logger.debug("TokenDeltaTracker: \(String(format: "%.1f", (t1 - t0) * 1000), privacy: .public)ms")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let todayKey = df.string(from: Date())
            let todayRb = TokenDeltaTracker.shared.dailyRollbacks[todayKey] ?? .zero
            let hasRb = todayRb.total > 0
            let result = service.fetchTodayUsage()
            let t2 = CFAbsoluteTimeGetCurrent()
            self.logger.debug("fetchTodayUsage: \(String(format: "%.1f", (t2 - t1) * 1000), privacy: .public)ms")

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
                    self.error = "无法读取数据库"
                }
                self.isLoading = false
                if apiKey.isEmpty {
                    self.deepseekBalance = nil
                    self.deepseekLoading = false
                }
            }

            // 写入 widget_data.json（由定时器控制频率，不额外触发 WidgetKit 重载）
            guard let result else {
                self.logger.debug("Total refresh: no data, skipped")
                return
            }
            let w0 = CFAbsoluteTimeGetCurrent()
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
                todayCost: result.todayCost
            )
            let combined = CombinedWidgetData(
                todayUsage: widgetUsage,
                monthlyHeatmap: self.service.fetchMonthData(),
                yearlyHeatmap: self.service.fetchYearlyData()
            )
            if let encoded = try? JSONEncoder().encode(combined),
               let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") {
                let url = container.appendingPathComponent("widget_data.json")
                // 数据未变更则不写入，避免无意义触发 WidgetKit 刷新
                if let existing = try? Data(contentsOf: url), existing == encoded {
                    return
                }
                try? encoded.write(to: url, options: .atomic)
                WidgetCenter.shared.reloadTimelines(ofKind: "TokenCheckLargeWidgetV2")
                WidgetCenter.shared.reloadTimelines(ofKind: "TokenCheckWidgetV2")
                WidgetCenter.shared.reloadTimelines(ofKind: "TokenCheckSmallWidgetV2")
            }
            self.logger.debug("widget data write: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - w0) * 1000), privacy: .public)ms")
            self.logger.debug("Total refresh: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
        }
    }
}
