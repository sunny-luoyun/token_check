import Foundation

/// 读取结果。
/// 区分「文件缺失/容器不可用」与「文件存在但损坏/无法解码」非常关键：
/// - `.notFound`  = 用户从未配置过（或容器暂不可用），允许用默认值撑起列表展示；
/// - `.corrupted` = 用户已配置过但文件/内容损坏，**禁止**用默认值撑起后回写（否则会把自定义价格覆盖成默认并固化）。
enum StorageReadResult<T> {
    case success(T)
    case notFound
    case corrupted
}

final class SharedStorage {
    static let store = SharedStorage()

    static let pricingRulesUpdated = Notification.Name("com.luoyun.tokencheck.pricingRulesUpdated")

    private let appGroupIdentifier = "group.com.luoyun.tokencheck"

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private let queue = DispatchQueue(label: "com.luoyun.tokencheck.shared-storage", qos: .utility)

    private func fileURL(for key: String) -> URL? {
        containerURL?.appendingPathComponent("\(key).json")
    }

    /// 同步读取，并区分「未配置」与「内容损坏」。
    func readResult<T: Decodable>(_ key: String, type: T.Type) -> StorageReadResult<T> {
        queue.sync {
            guard let url = fileURL(for: key),
                  FileManager.default.fileExists(atPath: url.path) else {
                return .notFound
            }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                return .corrupted
            }
            return .success(decoded)
        }
    }

    /// 兼容入口：仅读取成功时返回非 nil，其余返回 nil。
    func read<T: Decodable>(_ key: String, type: T.Type) -> T? {
        if case .success(let value) = readResult(key, type: type) { return value }
        return nil
    }

    /// 同步落盘：保证调用方返回时数据已写入磁盘。
    /// 原实现用 `queue.async`，用户改完价格后若立刻退出 / 更新 / 重编译，
    /// 异步块可能还没执行到 `data.write` 就被中断，导致价格回退默认。改为同步写后消除此竞态。
    func write<T: Encodable>(_ key: String, value: T) {
        queue.sync {
            guard let url = fileURL(for: key),
                  let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.pricingRulesUpdated, object: nil)
        }
    }
}
