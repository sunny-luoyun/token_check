import WidgetKit
import SwiftUI
import SQLite3

// MARK: - Timeline Entry

struct TokenStatsEntry: TimelineEntry {
    let date: Date
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let sessionCount: Int
    let dailyTokens: [DayTokenData]
    let total7Day: Int
}

struct DayTokenData: Identifiable {
    let id: String
    let date: Date
    let totalTokens: Int
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> TokenStatsEntry {
        TokenStatsEntry(
            date: Date(),
            totalTokens: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            sessionCount: 0,
            dailyTokens: [],
            total7Day: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenStatsEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenStatsEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadEntry() -> TokenStatsEntry {
        guard let db = openDB() else {
            return emptyEntry()
        }
        defer { sqlite3_close(db) }

        let todayStart = todayStartMilliseconds()
        let sevenDaysAgo = todayStart - 6 * 86_400 * 1000

        guard let row = fetchTodayRow(db, todayStart) else {
            return emptyEntry()
        }
        let dailyTokens = fillMissingDays(fetchDailyTokens(db, sevenDaysAgo) ?? [], since: sevenDaysAgo)
        let total7Day = dailyTokens.map(\.totalTokens).reduce(0, +)
        let total = row.input + row.cacheRead + row.output

        return TokenStatsEntry(
            date: Date(),
            totalTokens: total,
            inputTokens: row.input,
            outputTokens: row.output,
            cacheReadTokens: row.cacheRead,
            sessionCount: row.sessions,
            dailyTokens: dailyTokens,
            total7Day: total7Day
        )
    }

    private func emptyEntry() -> TokenStatsEntry {
        TokenStatsEntry(
            date: Date(),
            totalTokens: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            sessionCount: 0,
            dailyTokens: [],
            total7Day: 0
        )
    }

    // MARK: - Database Helpers

    private func openDB() -> OpaquePointer? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else { return nil }
        sqlite3_busy_timeout(db, 5000)
        return db
    }

    private func todayStartMilliseconds() -> Int64 {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return Int64(today.timeIntervalSince1970 * 1000)
    }

    private func fetchTodayRow(_ db: OpaquePointer, _ cutoff: Int64) -> (input: Int, output: Int, cacheRead: Int, sessions: Int)? {
        let sql = """
            SELECT COALESCE(SUM(tokens_input), 0),
                   COALESCE(SUM(tokens_output), 0),
                   COALESCE(SUM(tokens_cache_read), 0),
                   COUNT(*)
            FROM session
            WHERE time_created > ?
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (int(stmt, 0), int(stmt, 1), int(stmt, 2), int(stmt, 3))
    }

    private func fetchDailyTokens(_ db: OpaquePointer, _ cutoff: Int64) -> [DayTokenData]? {
        let sql = """
            SELECT date(datetime(time_created / 1000, 'unixepoch', 'localtime')) AS day,
                   COALESCE(SUM(tokens_input + tokens_cache_read + tokens_output), 0) AS total
            FROM session
            WHERE time_created > ?
            GROUP BY day
            ORDER BY day
        """
        var stmt_: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt_, nil) == SQLITE_OK,
              let stmt = stmt_ else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        var tokens: [DayTokenData] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let dateStr = String(cString: cStr)
            let total = Int(sqlite3_column_int64(stmt, 1))
            guard let date = df.date(from: dateStr) else { continue }
            tokens.append(DayTokenData(id: dateStr, date: date, totalTokens: total))
        }
        return tokens.isEmpty ? nil : tokens
    }

    private func fillMissingDays(_ tokens: [DayTokenData], since cutoffMs: Int64) -> [DayTokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        let dayCount = cal.dateComponents([.day], from: cutoffDate, to: today).day! + 1
        let existing = Dictionary(uniqueKeysWithValues: tokens.map { (cal.startOfDay(for: $0.date), $0) })
        var result: [DayTokenData] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for i in 0..<dayCount {
            guard let date = cal.date(byAdding: .day, value: i, to: cutoffDate) else { continue }
            let start = cal.startOfDay(for: date)
            if let item = existing[start] {
                result.append(item)
            } else {
                result.append(DayTokenData(id: df.string(from: date), date: date, totalTokens: 0))
            }
        }
        return result
    }

    private func int(_ stmt: OpaquePointer, _ idx: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, idx))
    }
}

// MARK: - Widget View

struct TokenStatsWidgetEntryView: View {
    var entry: TokenStatsEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallView
            default:
                mediumView
            }
        }
        .containerBackground(for: .widget) {
            Color(.windowBackgroundColor)
        }
    }

    // MARK: - Small

    private var smallView: some View {
        VStack(spacing: 6) {
            headerLabel("今日 Token")
                .font(.caption2)
            Spacer()
            Text(formatTokens(entry.totalTokens))
                .font(.title.monospaced().bold())
                .foregroundStyle(.blue)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 0) {
                statItem("输入", formatTokens(entry.inputTokens), .blue)
                Spacer(minLength: 0)
                statItem("缓存", formatTokens(entry.cacheReadTokens), .purple)
                Spacer(minLength: 0)
                statItem("输出", formatTokens(entry.outputTokens), .green)
            }
            .font(.caption2)
            HStack(spacing: 0) {
                Spacer()
                Label("\(entry.sessionCount)", systemImage: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Medium

    private var mediumView: some View {
        VStack(spacing: 0) {
            HStack {
                headerLabel("今日 Token 用量")
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 10)

            Text(formatTokens(entry.totalTokens))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)

            HStack(spacing: 0) {
                statItem("输入", formatTokens(entry.inputTokens), .blue)
                Spacer()
                statItem("缓存", formatTokens(entry.cacheReadTokens), .purple)
                Spacer()
                statItem("输出", formatTokens(entry.outputTokens), .green)
                Spacer()
                statItem("会话", "\(entry.sessionCount)", .orange)
            }
            .font(.caption)

            if !entry.dailyTokens.isEmpty {
                Divider()
                    .padding(.vertical, 8)
                HStack {
                    Text("近 7 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("共 \(formatTokens(entry.total7Day))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                progressBar
                    .padding(.top, 4)
            }
        }
        .padding(16)
    }

    private var progressBar: some View {
        let maxVal = entry.dailyTokens.map(\.totalTokens).max() ?? 1
        let barMax: CGFloat = 100
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(entry.dailyTokens) { item in
                    let ratio = CGFloat(item.totalTokens) / CGFloat(maxVal)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.blue.gradient)
                        .frame(width: (geo.size.width - CGFloat(entry.dailyTokens.count - 1) * 2) / CGFloat(entry.dailyTokens.count),
                               height: max(4, ratio * 24))
                        .frame(maxHeight: 24, alignment: .bottom)
                }
            }
        }
        .frame(height: 24)
    }

    // MARK: - Helpers

    private func headerLabel(_ text: String) -> some View {
        Label(text, systemImage: "chart.bar.fill")
            .foregroundStyle(.blue)
            .font(.headline)
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            String(format: "%.0fK", Double(n) / 1_000)
        } else {
            "\(n)"
        }
    }
}

// MARK: - Widget

@main
struct TokenStatsWidget: Widget {
    let kind = "com.luoyun.tokencheck.tokenstatswidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TokenStatsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Token 用量")
        .description("查看今日 Token 使用量统计")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
