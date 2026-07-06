import Foundation

/// Common interface for LLM clients (OpenAI-compatible and Claude).
protocol LLMClient: Sendable {
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String
    func warmUp(baseURL: String) async
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
