import Foundation
import SQLite3

final class TokenDeltaTracker {
    static let shared = TokenDeltaTracker()

    private(set) var rollbackRecord = RollbackRecord.zero
    private(set) var sessionRollbacks: [String: TokenData] = [:]
    private(set) var modelRollbacks: [String: TokenData] = [:]

    var hasRollbackData: Bool {
        rollbackRecord.total > 0
    }

    private init() {}

    func refresh(db: OpaquePointer) {
        var sessionTokens: [String: TokenData] = [:]
        var sessionModels: [String: String] = [:]
        var pendingRollbacks: [String: TokenData] = [:]
        var pendingRollbackModels: [String: String] = [:]

        var rb = RollbackRecord.zero
        var sRb: [String: TokenData] = [:]
        var mRb: [String: TokenData] = [:]

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

            if let modelKey = extractModelKey(from: info) {
                sessionModels[aggregateId] = modelKey
            }

            let hasRevert = info["revert"] != nil

            if hasRevert {
                pendingRollbacks[aggregateId] = sessionTokens[aggregateId] ?? tokens
                pendingRollbackModels[aggregateId] = sessionModels[aggregateId]
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
                    rb += positiveRollback
                    sRb[aggregateId] = (sRb[aggregateId] ?? .zero) + positiveRollback
                    let modelKey = pendingRollbackModels[aggregateId] ?? sessionModels[aggregateId]
                    if let mk = modelKey {
                        mRb[mk] = (mRb[mk] ?? .zero) + positiveRollback
                    }
                }
                pendingRollbacks.removeValue(forKey: aggregateId)
                pendingRollbackModels.removeValue(forKey: aggregateId)
                sessionTokens[aggregateId] = tokens
            } else {
                sessionTokens[aggregateId] = tokens
            }
        }

        rollbackRecord = rb
        sessionRollbacks = sRb
        modelRollbacks = mRb
    }

    private func extractModelKey(from info: [String: Any]) -> String? {
        guard let modelDict = info["model"] as? [String: Any],
              let modelId = modelDict["id"] as? String else { return nil }
        let variant = modelDict["variant"] as? String ?? "default"
        let normalized = variant == "max" ? "default" : variant
        return "\(modelId)/\(normalized)"
    }
}
