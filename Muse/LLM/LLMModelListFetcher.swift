import Foundation

/// 拉取线上服务商的可用模型列表（2026-06-11 用户拍板新增）。
/// OpenAI 兼容口走 GET {base}/models；Claude 走 Anthropic 原生接口。
enum LLMModelListFetcher {

    enum FetchError: Error, LocalizedError {
        case unsupportedProvider
        case invalidURL
        case server(Int, String)
        case emptyList

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider: return L("该服务商不支持拉取模型列表", "Provider does not support model listing")
            case .invalidURL: return L("API 地址无效", "Invalid API base URL")
            case .server(let code, let body): return "HTTP \(code): \(body)"
            case .emptyList: return L("服务商返回了空模型列表", "Provider returned an empty model list")
            }
        }
    }

    static func fetchModels(
        provider: LLMProvider,
        apiKey: String,
        baseURL: String
    ) async throws -> [String] {
        // 本地 Qwen 模型清单是内置静态的，不走网络
        guard provider != .localQwen else {
            return LocalQwenLLMConfig.knownModels
                .filter { $0.path != nil }
                .map(\.name)
        }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = base.isEmpty ? provider.defaultBaseURL : base

        var request: URLRequest
        if provider == .claude {
            guard let url = URL(string: normalized(resolvedBase) + "/models") else {
                throw FetchError.invalidURL
            }
            request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            guard let url = URL(string: normalized(resolvedBase) + "/models") else {
                throw FetchError.invalidURL
            }
            request = URLRequest(url: url, timeoutInterval: 12)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw FetchError.server(http.statusCode, body)
        }

        let ids = parseModelIDs(from: data)
        guard !ids.isEmpty else { throw FetchError.emptyList }
        return ids
    }

    /// 去掉尾部斜杠；DeepSeek 这类默认地址不带 /v1 的，补上
    static func normalized(_ base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        // 已带版本段（/v1、/v3、/v4、/v1beta/openai、compatible-mode/v1 等）的不再追加
        let hasVersionSegment = b.range(
            of: #"/v\d+[a-z]*(/openai)?$|/api/paas/v\d+$|/compatible-mode/v\d+$"#,
            options: .regularExpression
        ) != nil
        if !hasVersionSegment {
            b += "/v1"
        }
        return b
    }

    /// 兼容 OpenAI {"data":[{"id":..}]} 与 Anthropic {"data":[{"id":..}]}，
    /// 以及个别返回 {"models":[{"id"/"name":..}]} 的实现
    static func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let array = (json["data"] as? [[String: Any]])
            ?? (json["models"] as? [[String: Any]])
            ?? []
        let ids = array.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        return ids.sorted()
    }
}
