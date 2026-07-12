import Foundation

enum AppDatabase {
    static let opencodePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db").path
    static let devecoPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/deveco/deveco.db").path

    static var devecoExists: Bool {
        FileManager.default.fileExists(atPath: devecoPath)
    }
}
