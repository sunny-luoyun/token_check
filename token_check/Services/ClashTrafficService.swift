import Foundation
import OSLog
import SQLite3

struct ClashSubscription: Decodable {
    let label: String
    let url: String
}

struct ClashTrafficData: Codable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64
    let label: String
    let lastUpdated: Date

    var used: Int64 { upload + download }
    var remaining: Int64 { total - used }
}

final class ClashTrafficService {
    private let logger = Logger(subsystem: "com.luoyun.tokencheck", category: "clash-traffic")

    private var flclashDbPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/com.follow.clash/database.sqlite"
    }

    private var appGroupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luoyun.tokencheck")
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "ClashMeta/1.18"]
        return URLSession(configuration: config)
    }()

    /// 拉取订阅流量并写入 App Group。返回是否成功（含 subscription-userinfo 头并解析出总量）。
    func fetchAndWriteTrafficData() -> Bool {
        guard let sub = readSubscriptionURL() else {
            logger.debug("未找到 Clash 订阅 URL")
            return false
        }

        logger.debug("请求订阅流量数据: label=\(sub.label) url=\(sub.url, privacy: .private)")

        guard let url = URL(string: sub.url) else {
            logger.error("无效的订阅 URL")
            return false
        }

        var request = URLRequest(url: url)
        request.setValue("ClashMeta/1.18", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var userInfoHeader: String?

        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                self.logger.error("请求订阅失败: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if let value = httpResponse.allHeaderFields["Subscription-Userinfo"] as? String {
                    userInfoHeader = value
                } else if let value = httpResponse.allHeaderFields["subscription-userinfo"] as? String {
                    userInfoHeader = value
                } else {
                    self.logger.error("响应中未找到 subscription-userinfo 头，所有 headers: \(httpResponse.allHeaderFields)")
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)

        guard let header = userInfoHeader else {
            logger.error("获取 subscription-userinfo 失败（订阅地址不可达或代理出口异常）")
            return false
        }

        guard let data = parseSubscriptionInfo(header) else {
            logger.error("解析 subscription-userinfo 失败: \(header)")
            return false
        }

        let traffic = ClashTrafficData(
            upload: data.0,
            download: data.1,
            total: data.2,
            expire: data.3,
            label: sub.label,
            lastUpdated: Date()
        )

        writeToAppGroup(traffic)
        return true
    }

    private func readSubscriptionURL() -> ClashSubscription? {
        let path = flclashDbPath
        guard FileManager.default.fileExists(atPath: path) else {
            logger.debug("FlClash DB 不存在: \(path)")
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            logger.error("打开 FlClash DB 失败: \(path)")
            return nil
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 3000)

        let sql = "SELECT label, url FROM profiles WHERE url IS NOT NULL AND url != ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            return nil
        }
        defer { sqlite3_finalize(s) }

        while sqlite3_step(s) == SQLITE_ROW {
            guard let labelPtr = sqlite3_column_text(s, 0) else { continue }
            guard let urlPtr = sqlite3_column_text(s, 1) else { continue }
            return ClashSubscription(
                label: String(cString: labelPtr),
                url: String(cString: urlPtr)
            )
        }

        return nil
    }

    private func parseSubscriptionInfo(_ header: String) -> (Int64, Int64, Int64, Int64)? {
        var upload: Int64 = 0
        var download: Int64 = 0
        var total: Int64 = 0
        var expire: Int64 = 0

        for pair in header.split(separator: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Int64(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            switch key {
            case "upload":   upload = value
            case "download": download = value
            case "total":    total = value
            case "expire":   expire = value
            default: break
            }
        }

        guard total > 0 else { return nil }
        return (upload, download, total, expire)
    }

    private func writeToAppGroup(_ data: ClashTrafficData) {
        guard let container = appGroupContainer else {
            logger.error("App Group container 不可用")
            return
        }

        let url = container.appendingPathComponent("clash_traffic.json")
        guard let encoded = try? JSONEncoder().encode(data) else {
            logger.error("编码 ClashTrafficData 失败")
            return
        }

        do {
            try encoded.write(to: url, options: .atomic)
            logger.debug("clash_traffic.json 写入完成: 已用=\(data.used) 总量=\(data.total) label=\(data.label)")
        } catch {
            logger.error("写入 clash_traffic.json 失败: \(error.localizedDescription)")
        }
    }
}
