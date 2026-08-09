import Foundation

enum AppDatabase {
    /// 真实用户主目录：沙盒内 `homeDirectoryForCurrentUser` 返回容器路径（~/Library/Containers/<id>/Data），
    /// 无法命中 temporary-exception 只读例外，需用 getpwuid 取真实用户目录
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
