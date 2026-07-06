import Foundation

/// 应用 JSON 文件持久化的薄封装：统一目录创建、原子写与编码格式，
/// 供 SnippetStorage / HotwordStorage 等复用此前逐文件重复的读写样板。
enum JSONFileStore {

    /// 读取并解码；文件不存在或解码失败时返回 nil。
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 编码并原子写入（自动创建父目录）；编码使用 prettyPrinted + withoutEscapingSlashes。
    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try writeOrThrow(value, to: url)
        } catch {
            AppLogger.log("[JSONFileStore] 写入失败 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 编码并原子写入；失败时向调用方暴露错误，供关键设置保存路径处理。
    static func writeOrThrow<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
