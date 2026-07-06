import Foundation
import os

/// 统一的控制台日志门面，替代散落各处的 NSLog，收敛到 os.Logger（系统统一日志）。
///
/// 职责划分：
/// - `AppLogger`：控制台/实时日志（os.Logger），可在 Console.app 按 subsystem 过滤。
/// - `DebugFileLogger`：可落盘的 debug.log（带轮转与 0600 权限），用于事后排障。
///
/// 二者各司其职、互不重复。需要同时记录时，分别调用即可（与历史行为一致）。
///
/// 说明：这里对插值内容显式标记 `.public`，以保持与 NSLog 等价的可见性
/// （敏感信息已在各调用点脱敏，不会传入明文凭证）。
enum AppLogger {

    private static let subsystem = "pro.daliang.muse"

    /// 记录一条信息级日志到系统统一日志。
    static func log(_ message: String, category: String = "app") {
        Logger(subsystem: subsystem, category: category).log("\(message, privacy: .public)")
    }
}
