import Foundation
import SQLite3

final class TokenDeltaTracker {
    static let shared = TokenDeltaTracker()

    private let queue = DispatchQueue(label: "com.luoyun.tokencheck.delta-tracker")

    private var _rollbackRecord = RollbackRecord.zero
    private var _sessionRollbacks: [String: TokenData] = [:]
    private var _modelRollbacks: [String: TokenData] = [:]
    private var _dailyRollbacks: [String: RollbackRecord] = [:]
    private var _dailyModelRollbacks: [String: [String: TokenData]] = [:]
    private var _dailyConsumption: [String: TokenData] = [:]
    private var _dailyModelConsumption: [String: [String: TokenData]] = [:]

    var rollbackRecord: RollbackRecord { queue.sync { _rollbackRecord } }
    var sessionRollbacks: [String: TokenData] { queue.sync { _sessionRollbacks } }
    var modelRollbacks: [String: TokenData] { queue.sync { _modelRollbacks } }
    var dailyRollbacks: [String: RollbackRecord] { queue.sync { _dailyRollbacks } }
    var dailyModelRollbacks: [String: [String: TokenData]] { queue.sync { _dailyModelRollbacks } }
    var dailyConsumption: [String: TokenData] { queue.sync { _dailyConsumption } }
    var dailyModelConsumption: [String: [String: TokenData]] { queue.sync { _dailyModelConsumption } }

    var hasRollbackData: Bool {
        rollbackRecord.total > 0
    }

    private static let dailyDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private init() {}

    func refresh(db: OpaquePointer) {
        var sessionTokens: [String: TokenData] = [:]
        var sessionModels: [String: String] = [:]
        var pendingRollbacks: [String: TokenData] = [:]
        var pendingRollbackModels: [String: String] = [:]
        var pendingRollbackTimestamps: [String: Int64] = [:]

        var rb = RollbackRecord.zero
        var sRb: [String: TokenData] = [:]
        var mRb: [String: TokenData] = [:]
        var dRb: [String: RollbackRecord] = [:]
        var dMRb: [String: [String: TokenData]] = [:]
        var dCon: [String: TokenData] = [:]
        var dMCon: [String: [String: TokenData]] = [:]

        let sql = """
            SELECT rowid, aggregate_id, type, data
            FROM event
            ORDER BY rowid
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let aggregateId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let type = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  type == "session.updated.1",
                  let data = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let tokensDict = info["tokens"] as? [String: Any]
            else { continue }

            let tokens = TokenData(
                tokensInput: (tokensDict["input"] as? Int) ?? 0,
                tokensOutput: (tokensDict["output"] as? Int) ?? 0,
                tokensReasoning: (tokensDict["reasoning"] as? Int) ?? 0,
                tokensCacheRead: ((tokensDict["cache"] as? [String: Any])?["read"] as? Int) ?? 0,
                tokensCacheWrite: ((tokensDict["cache"] as? [String: Any])?["write"] as? Int) ?? 0
            )

            let eventTimestamp: Int64 = {
                if let timeObj = info["time"] as? [String: Any], let updated = timeObj["updated"] as? Int64 {
                    return updated
                }
                return 0
            }()

            if let modelKey = extractModelKey(from: info) {
                sessionModels[aggregateId] = modelKey
            }

            let hasRevert = info["revert"] != nil

            let prevSessionState = sessionTokens[aggregateId]
            if !hasRevert, eventTimestamp > 0 {
                if let prev = prevSessionState {
                    let delta = TokenData(
                        tokensInput: max(0, tokens.tokensInput - prev.tokensInput),
                        tokensOutput: max(0, tokens.tokensOutput - prev.tokensOutput),
                        tokensReasoning: max(0, tokens.tokensReasoning - prev.tokensReasoning),
                        tokensCacheRead: max(0, tokens.tokensCacheRead - prev.tokensCacheRead),
                        tokensCacheWrite: max(0, tokens.tokensCacheWrite - prev.tokensCacheWrite)
                    )
                    if delta.total > 0 {
                        let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                        dCon[dateKey] = (dCon[dateKey] ?? .zero) + delta
                        if let modelKey = sessionModels[aggregateId] {
                            var dm = dMCon[dateKey] ?? [:]
                            dm[modelKey] = (dm[modelKey] ?? .zero) + delta
                            dMCon[dateKey] = dm
                        }
                    }
                } else {
                    if tokens.total > 0 {
                        let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(eventTimestamp) / 1000))
                        dCon[dateKey] = (dCon[dateKey] ?? .zero) + tokens
                        if let modelKey = sessionModels[aggregateId] ?? extractModelKey(from: info) {
                            var dm = dMCon[dateKey] ?? [:]
                            dm[modelKey] = (dm[modelKey] ?? .zero) + tokens
                            dMCon[dateKey] = dm
                        }
                    }
                }
            }

            if hasRevert {
                pendingRollbacks[aggregateId] = sessionTokens[aggregateId] ?? tokens
                pendingRollbackModels[aggregateId] = sessionModels[aggregateId]
                pendingRollbackTimestamps[aggregateId] = eventTimestamp
                sessionTokens[aggregateId] = tokens
            } else if let preTokens = pendingRollbacks[aggregateId] {
                let diff = preTokens - tokens
                let positiveRollback = TokenData(
                    tokensInput: max(0, diff.tokensInput),
                    tokensOutput: max(0, diff.tokensOutput),
                    tokensReasoning: max(0, diff.tokensReasoning),
                    tokensCacheRead: max(0, diff.tokensCacheRead),
                    tokensCacheWrite: max(0, diff.tokensCacheWrite)
                )
                if positiveRollback.total > 0 {
                    let rollbackTimestamp = pendingRollbackTimestamps[aggregateId] ?? eventTimestamp
                    let dateKey = Self.dailyDateFormatter.string(from: Date(timeIntervalSince1970: Double(rollbackTimestamp) / 1000))

                    rb += positiveRollback
                    sRb[aggregateId] = (sRb[aggregateId] ?? .zero) + positiveRollback

                    var existing = dRb[dateKey] ?? .zero
                    existing += positiveRollback
                    dRb[dateKey] = existing

                    let modelKey = pendingRollbackModels[aggregateId] ?? sessionModels[aggregateId]
                    if let mk = modelKey {
                        mRb[mk] = (mRb[mk] ?? .zero) + positiveRollback
                        var dailyModel = dMRb[dateKey] ?? [:]
                        dailyModel[mk] = (dailyModel[mk] ?? .zero) + positiveRollback
                        dMRb[dateKey] = dailyModel
                    }
                }
                pendingRollbacks.removeValue(forKey: aggregateId)
                pendingRollbackModels.removeValue(forKey: aggregateId)
                pendingRollbackTimestamps.removeValue(forKey: aggregateId)
                sessionTokens[aggregateId] = tokens
            } else {
                sessionTokens[aggregateId] = tokens
            }
        }

        queue.sync {
            _rollbackRecord = rb
            _sessionRollbacks = sRb
            _modelRollbacks = mRb
            _dailyRollbacks = dRb
            _dailyModelRollbacks = dMRb
            _dailyConsumption = dCon
            _dailyModelConsumption = dMCon
        }
    }

    func rollback(year: String?, month: String?, day: String?) -> RollbackRecord {
        dailyRollbacks.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(year: String?, month: String?, day: String?) -> [String: TokenData] {
        let matchingKeys = Set(dailyModelRollbacks.keys.filter { key in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        })
        var result: [String: TokenData] = [:]
        for key in matchingKeys {
            guard let modelRb = dailyModelRollbacks[key] else { continue }
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func rollback(from startDate: Date, to endDate: Date) -> RollbackRecord {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyRollbacks.filter { keys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(from startDate: Date, to endDate: Date) -> [String: TokenData] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        var result: [String: TokenData] = [:]
        for (key, modelRb) in dailyModelRollbacks where keys.contains(key) {
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    private func dateKeysInRange(from startDate: Date, to endDate: Date) -> Set<String> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else { return [] }
        var keys: Set<String> = []
        var current = start
        while current < end {
            keys.insert(Self.dailyDateFormatter.string(from: current))
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return keys
    }

    func rollback(days: Int) -> RollbackRecord {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return .zero }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        return dailyRollbacks.filter { dateKeys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelRollbacks(days: Int) -> [String: TokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [:] }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        var result: [String: TokenData] = [:]
        for (key, modelRb) in dailyModelRollbacks where dateKeys.contains(key) {
            for (modelKey, tokens) in modelRb {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    // MARK: - Daily Consumption Query Methods

    func consumption(year: String?, month: String?, day: String?) -> TokenData {
        dailyConsumption.filter { key, _ in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(year: String?, month: String?, day: String?) -> [String: TokenData] {
        let matchingKeys = Set(dailyModelConsumption.keys.filter { key in
            Self.matchesDateFilter(key, year: year, month: month, day: day)
        })
        var result: [String: TokenData] = [:]
        for key in matchingKeys {
            guard let mc = dailyModelConsumption[key] else { continue }
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func consumption(from startDate: Date, to endDate: Date) -> TokenData {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        return dailyConsumption.filter { keys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(from startDate: Date, to endDate: Date) -> [String: TokenData] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        var result: [String: TokenData] = [:]
        for (key, mc) in dailyModelConsumption where keys.contains(key) {
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    func consumption(days: Int) -> TokenData {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return .zero }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        return dailyConsumption.filter { dateKeys.contains($0.key) }.reduce(.zero) { $0 + $1.value }
    }

    func modelConsumption(days: Int) -> [String: TokenData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [:] }
        var dateKeys: Set<String> = []
        for i in 0..<days {
            if let date = cal.date(byAdding: .day, value: i, to: startDate) {
                dateKeys.insert(Self.dailyDateFormatter.string(from: date))
            }
        }
        var result: [String: TokenData] = [:]
        for (key, mc) in dailyModelConsumption where dateKeys.contains(key) {
            for (modelKey, tokens) in mc {
                result[modelKey] = (result[modelKey] ?? .zero) + tokens
            }
        }
        return result
    }

    // MARK: - Daily ModelUsage Conversion

    func dailyModelUsage(from startDate: Date, to endDate: Date) -> [DailyModelUsage] {
        let keys = dateKeysInRange(from: startDate, to: endDate)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        var result: [DailyModelUsage] = []
        for dateKey in keys.sorted() {
            guard let date = df.date(from: dateKey) else { continue }
            guard let mc = dailyModelConsumption[dateKey], !mc.isEmpty else { continue }
            for (modelKey, tokens) in mc {
                let parts = modelKey.split(separator: "/")
                let modelId = String(parts[0])
                let variant = parts.count > 1 ? String(parts[1]) : "default"
                result.append(DailyModelUsage(
                    id: "\(dateKey)/\(modelKey)",
                    date: date,
                    modelId: modelId,
                    variant: variant,
                    inputTokens: tokens.tokensInput,
                    outputTokens: tokens.tokensOutput,
                    cacheReadTokens: tokens.tokensCacheRead,
                    reasoningTokens: tokens.tokensReasoning,
                    cacheWriteTokens: tokens.tokensCacheWrite
                ))
            }
        }
        return result
    }

    private static func matchesDateFilter(_ dateKey: String, year: String?, month: String?, day: String?) -> Bool {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3 else { return false }
        if let y = year, String(parts[0]) != y { return false }
        if let m = month, String(parts[1]) != m { return false }
        if let d = day, String(parts[2]) != d { return false }
        return true
    }

    private func extractModelKey(from info: [String: Any]) -> String? {
        guard let modelDict = info["model"] as? [String: Any],
              let modelId = modelDict["id"] as? String else { return nil }
        let variant = modelDict["variant"] as? String ?? "default"
        let normalized = variant == "max" ? "default" : variant
        return "\(modelId)/\(normalized)"
    }
}
