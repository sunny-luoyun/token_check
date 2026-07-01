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
    @Published var adjustedTotal: Int = 0
    @Published var deepseekBalance: String?
    @Published var deepseekLoading = false

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "refresh")
    private let service = WidgetDataService()
    private var lastWidgetReload: Date = .distantPast
    private var refreshTimer: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    init() {
        setupPeriodicRefresh()
        setupWakeNotification()
        setupSettingsObserver()
        refresh(showLoading: false)
    }

    deinit {
        refreshTimer?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func setupPeriodicRefresh() {
        refreshTimer?.cancel()
        let interval = Self.readRefreshInterval()
        refreshTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh(showLoading: false)
            }
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
            let adjTotal = result.map { $0.totalTokens + todayRb.total } ?? 0

            // 主线程只更新 UI，不涉及任何跨进程调用
            DispatchQueue.main.async {
                self.hasRollback = hasRb
                self.rollbackTotal = todayRb.total
                self.adjustedInput = adjInput
                self.adjustedOutput = adjOutput
                self.adjustedCacheRead = adjCacheRead
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

            // 跨进程操作（UserDefaults + WidgetCenter）在后台执行，绝不阻塞主线程
            guard let result else {
                self.logger.debug("Total refresh: no data, skipped")
                return
            }
            let widgetUsage = TodayUsage(
                totalTokens: adjTotal,
                inputTokens: adjInput,
                outputTokens: adjOutput,
                cacheReadTokens: adjCacheRead,
                sessionCount: result.sessionCount,
                dailyTokens: result.dailyTokens,
                todayCost: result.todayCost
            )
            if let data = try? JSONEncoder().encode(widgetUsage),
               let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") {
                let w0 = CFAbsoluteTimeGetCurrent()
                defaults.set(data, forKey: "today_usage")
                self.logger.debug("UD write today_usage: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - w0) * 1000), privacy: .public)ms")
            }
            if let monthData = self.service.fetchMonthData(),
               let encoded = try? JSONEncoder().encode(monthData),
               let defaults = UserDefaults(suiteName: "group.com.luoyun.tokencheck") {
                let w0 = CFAbsoluteTimeGetCurrent()
                defaults.set(encoded, forKey: "monthly_heatmap")
                self.logger.debug("UD write monthly_heatmap: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - w0) * 1000), privacy: .public)ms")
            }
            if let yearlyData = self.service.fetchYearlyData(),
               let encoded = try? JSONEncoder().encode(yearlyData),
               let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck") {
                let w0 = CFAbsoluteTimeGetCurrent()
                let url = container.appendingPathComponent("yearly_heatmap.json")
                try? encoded.write(to: url, options: .atomic)
                self.logger.debug("file write yearly_heatmap: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - w0) * 1000), privacy: .public)ms")
            }
            let t3 = CFAbsoluteTimeGetCurrent()
            self.logger.debug("widget data write total: \(String(format: "%.1f", (t3 - t2) * 1000), privacy: .public)ms")
            // 节流：每 15 分钟 reload 一次 Widget，主线程调用避免 XPC 竞争
            let now = Date()
            guard now.timeIntervalSince(self.lastWidgetReload) >= 900 else {
                self.logger.debug("reloadAllTimelines throttled, skip")
                self.logger.debug("Total refresh: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000), privacy: .public)ms")
                return
            }
            self.lastWidgetReload = now
            let t4 = CFAbsoluteTimeGetCurrent()
            self.logger.debug("reloadAllTimelines called, total refresh: \(String(format: "%.1f", (t4 - t0) * 1000), privacy: .public)ms")
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
