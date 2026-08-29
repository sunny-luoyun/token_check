import Foundation

enum AppDatabase {
    /// 真实用户主目录：主 App 未启用 App Sandbox（见 entitlements，仅有 App Group），
    /// `homeDirectoryForCurrentUser` 通常返回真实主目录；但为防御未来启用沙盒后
    /// 返回容器路径（~/Library/Containers/<id>/Data）导致读不到数据库，
    /// 统一用 getpwuid 取真实用户目录
    private static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    static let opencodePath = URL(fileURLWithPath: realHome)
        .appendingPathComponent(".local/share/opencode/opencode.db").path
    static let devecoPath = URL(fileURLWithPath: realHome)
        .appendingPathComponent(".local/share/deveco/deveco.db").path

    static var devecoExists: Bool {
        FileManager.default.fileExists(atPath: devecoPath)
    }
}
