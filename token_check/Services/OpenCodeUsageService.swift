import Foundation
import OSLog

/// OpenCode 官方用量 API 返回的结构化数据
struct OpenCodeOfficialUsage {
    let monthlyPercent: Int      // 月度已用百分比 (0-100)
    let monthlyResetsAt: Date?   // 月度重置时间
    let monthlyStatus: String    // "ok" / "approaching_limit" / "limit_reached"
    let rollingPercent: Int
    let rollingResetsAt: Date?
    let weeklyPercent: Int
    let weeklyResetsAt: Date?
}

/// OpenCode 官方用量 API 服务
/// API: GET https://opencode.ai/zen/go/v1/usage
/// Headers: Authorization: Bearer <key>, x-api-key: <key>
final class OpenCodeUsageService {
    static let shared = OpenCodeUsageService()

    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "opencode-usage")
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    /// 从官方 API 获取用量数据
    func fetchUsage(apiKey: String) async -> OpenCodeOfficialUsage? {
        guard !apiKey.isEmpty else { return nil }

        let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("OpenCode usage API 返回非 200: \(code)")
                return nil
            }

            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let usage = decoded.usage

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Fallback: 没有毫秒部分时也能解析
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            func parseDate(_ str: String) -> Date? {
                formatter.date(from: str) ?? fallbackFormatter.date(from: str)
            }

            return OpenCodeOfficialUsage(
                monthlyPercent: usage.monthly.percent,
                monthlyResetsAt: parseDate(usage.monthly.resetsAt),
                monthlyStatus: usage.monthly.status,
                rollingPercent: usage.rolling.percent,
                rollingResetsAt: parseDate(usage.rolling.resetsAt),
                weeklyPercent: usage.weekly.percent,
                weeklyResetsAt: parseDate(usage.weekly.resetsAt)
            )
        } catch {
            logger.error("OpenCode usage API 请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Response Models

    private struct UsageResponse: Codable {
        let usage: UsageData
    }

    private struct UsageData: Codable {
        let rolling: PeriodData
        let weekly: PeriodData
        let monthly: PeriodData
    }

    private struct PeriodData: Codable {
        let status: String
        let percent: Int
        let resetsAt: String
    }
}
