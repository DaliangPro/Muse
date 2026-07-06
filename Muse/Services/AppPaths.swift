import Foundation

/// 应用所有持久化路径的单一来源。
///
/// 数据根目录为 `~/Library/Application Support/Muse`。
/// 早期版本曾用旧项目名目录，已由 `KeychainService.migrateAppSupportDirectory()` 一次性并入本目录。
enum AppPaths {

    /// 应用支持目录（仅计算路径，不保证目录已创建）。
    static var supportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
    }

    /// 返回支持目录下的子路径。
    static func support(_ component: String, isDirectory: Bool = false) -> URL {
        supportDir.appendingPathComponent(component, isDirectory: isDirectory)
    }

    /// 确保支持目录存在并返回它。
    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 识别历史数据库路径（HistoryStore 与 LanguageAssetStore 共用同一文件）。
    static var historyDBPath: String { support("history.db").path }
}
