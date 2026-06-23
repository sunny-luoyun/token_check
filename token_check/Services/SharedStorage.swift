import Foundation

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

    func read<T: Decodable>(_ key: String, type: T.Type) -> T? {
        queue.sync {
            guard let url = fileURL(for: key),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }

    func write<T: Encodable>(_ key: String, value: T) {
        queue.async {
            guard let url = self.fileURL(for: key),
                  let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.pricingRulesUpdated, object: nil)
            }
        }
    }
}
