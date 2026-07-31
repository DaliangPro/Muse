import Foundation

struct LLMCapabilityKey: Hashable, Sendable {
    let provider: LLMProvider
    let model: String
    let normalizedBaseURL: String
}

struct LLMProviderCapabilities: Sendable, Equatable {
    let supportsTemperature: Bool
    let supportsJSONMode: Bool
    let supportsReasoningControl: Bool
    let supportsDynamicMaxTokens: Bool
}

enum LLMProviderCapabilityResolver {

    static func key(provider: LLMProvider, config: LLMConfig) -> LLMCapabilityKey {
        let normalizedBaseURL = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return LLMCapabilityKey(
            provider: provider,
            model: config.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            normalizedBaseURL: normalizedBaseURL
        )
    }

    static func capabilities(
        provider: LLMProvider,
        config: LLMConfig
    ) -> LLMProviderCapabilities {
        _ = key(provider: provider, config: config)

        // 第一期采用保守协商：不主动发送 temperature / JSON mode / 动态 token
        // 字段，避免兼容端点拒绝后在客户端内部静默追加请求。推理控制只在现有
        // Provider+model 映射明确支持时使用；endpoint 仍进入 key，供后续缓存。
        return LLMProviderCapabilities(
            supportsTemperature: false,
            supportsJSONMode: false,
            supportsReasoningControl: provider.thinkingRequestField(for: config.model)
                .isExplicitlyControllable,
            supportsDynamicMaxTokens: false
        )
    }
}
