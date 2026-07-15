import Foundation

enum DebugFileLogger {

    private static let queue = DispatchQueue(label: "pro.daliang.muse.debug-file-logger")

    static var logURL: URL {
        AppPaths.ensureSupportDir().appendingPathComponent("debug.log")
    }

    static func startSession() {
        queue.async {
            rotateIfNeeded()
            append("--- session \(timestamp()) ---")
        }
    }

    static func log(_ message: String) {
        queue.async {
            append("[\(timestamp())] \(message)")
        }
    }

    /// REPAIR_PLAN K4：超限不再直接删除，归档为 debug.log.1 保留上一现场——
    /// 偶发问题常在「重启前最后几分钟」，2026-07-15 排查即因旧日志被删丢失关键案例。
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 256 * 1024
        else { return }

        let backupURL = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logURL, to: backupURL)
    }

    private static func append(_ line: String) {
        let entry = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
                try? handle.close()
            }
        } else {
            try? entry.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
