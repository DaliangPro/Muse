import Foundation

/// Common interface for LLM clients (OpenAI-compatible and Claude).
protocol LLMClient: Sendable {
    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String
    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence
    func warmUp(baseURL: String) async
}

extension LLMClient {
    /// 测试替身及不提供结构化推理信息的客户端可复用基础连通测试；
    /// 正式云端客户端会覆盖此实现并返回推理证据。
    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        _ = try await process(
            text: LLMThinkingModeValidator.probeText,
            prompt: "{text}",
            context: .connectivityProbe,
            config: config
        )
        return .unknown
    }
}

extension String {
    func removingPromptTextPlaceholder() -> String {
        self
            .replacingOccurrences(of: "{{text}}", with: "")
            .replacingOccurrences(of: "{text}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func separatedLLMMessages(with text: String) -> (system: String?, user: String) {
        let system = removingPromptTextPlaceholder()
        let user = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (system.isEmpty ? nil : system, user)
    }

    /// Remove `<think>...</think>` reasoning blocks emitted by models like DeepSeek.
    /// Handles both closed tags and unclosed/truncated tags.
    func strippingThinkTags() -> String {
        self
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<think>[\\s\\S]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
