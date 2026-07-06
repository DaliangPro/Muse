import Foundation

protocol AssetExtractionProvider: Sendable {
    func extractAssets(
        from records: [HistoryRecord],
        configuration: AssetExtractionConfiguration
    ) async throws -> AssetExtractionResult
}

enum AssetExtractionError: Error, LocalizedError {
    case missingLLMConfig
    case noSourceRecords
    case invalidProviderResponse(String)
    case timeout(Int)
    case unsupportedRecipe(String)

    var errorDescription: String? {
        switch self {
        case .missingLLMConfig:
            return L("未找到可用的 LLM 配置，无法执行语料提炼", "No available LLM configuration for asset extraction")
        case .noSourceRecords:
            return L("没有可用于提炼的历史记录", "No history records available for extraction")
        case .invalidProviderResponse(let raw):
            return L("提炼结果格式无效：\(raw)", "Invalid extraction response: \(raw)")
        case .timeout(let seconds):
            return L("模型 \(seconds) 秒未响应，已中止本次提炼", "Model timed out after \(seconds)s")
        case .unsupportedRecipe(let name):
            return L("当前提炼入口暂不支持“\(name)”方案", "The current extraction entry does not support the \(name) recipe yet")
        }
    }
}
