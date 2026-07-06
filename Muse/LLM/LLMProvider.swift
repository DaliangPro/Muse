import Foundation

// MARK: - Provider Enum

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case doubao
    case minimaxCN
    case minimaxIntl
    case bailian
    case kimi
    case openrouter
    case openai
    case gemini
    case deepseek
    case zhipu
    case claude
    case ollama
    case localQwen

    var displayName: String {
        switch self {
        case .doubao:      return L("豆包 (ByteDance ARK)", "Doubao (ByteDance ARK)")
        case .minimaxCN:   return L("MiniMax 国内", "MiniMax China")
        case .minimaxIntl: return L("MiniMax 海外", "MiniMax Global")
        case .bailian:     return L("百炼 (阿里云)", "Bailian (Alibaba Cloud)")
        case .kimi:        return L("Kimi (月之暗面)", "Kimi (Moonshot)")
        case .openrouter:  return "OpenRouter"
        case .openai:      return "OpenAI"
        case .gemini:      return "Gemini (Google)"
        case .deepseek:    return L("DeepSeek (深度求索)", "DeepSeek")
        case .zhipu:       return L("智谱 (GLM)", "Zhipu (GLM)")
        case .claude:      return "Claude (Anthropic)"
        case .ollama:      return L("Ollama (本地模型)", "Ollama (Local)")
        case .localQwen:   return L("本地 Qwen (离线)", "Local Qwen (Offline)")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .doubao:      return "https://ark.cn-beijing.volces.com/api/v3"
        case .minimaxCN:   return "https://api.minimaxi.com/v1"
        case .minimaxIntl: return "https://api.minimax.io/v1"
        case .bailian:     return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:        return "https://api.moonshot.ai/v1"
        case .openrouter:  return "https://openrouter.ai/api/v1"
        case .openai:      return "https://api.openai.com/v1"
        case .gemini:      return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek:    return "https://api.deepseek.com"
        case .zhipu:       return "https://open.bigmodel.cn/api/paas/v4"
        case .claude:      return "https://api.anthropic.com/v1"
        case .ollama:      return "http://localhost:11434/v1"
        case .localQwen:   return "http://127.0.0.1:0/v1"  // Dynamic port from SenseVoiceServerManager
        }
    }

    /// Whether this is a local provider bundled with the app (no external service).
    var isLocal: Bool {
        self == .localQwen || self == .ollama
    }

    /// Whether this provider requires an API key for authentication.
    var requiresAPIKey: Bool {
        self != .ollama && self != .localQwen
    }

    /// Thinking/reasoning disable strategy for this provider.
    /// Each provider uses a different field name to turn off chain-of-thought.
    /// Returns nil for providers where no explicit disable is needed or possible.
    var thinkingDisableField: ThinkingDisableField? {
        switch self {
        case .doubao, .kimi, .deepseek:
            // thinking: { type: "disabled" }
            return .thinking
        case .bailian:
            // enable_thinking: false (Qwen models)
            return .enableThinking
        case .zhipu:
            // reasoning_effort: "none" (GLM-4.5+)
            return .reasoningEffort
        case .ollama:
            // think: false
            return .think
        default:
            // OpenAI: defaults to none already for GPT-5.2+, risky for o3
            // Gemini: OpenAI-compat layer doesn't reliably support it
            // MiniMax: API doesn't support disabling reasoning (use needsReasoningSplit instead)
            // OpenRouter: proxy, can't generically handle
            return nil
        }
    }

    /// MiniMax M2+ models always reason and can't be turned off.
    /// reasoning_split=true separates thinking into reasoning_details field,
    /// keeping it out of delta.content so our SSE parser won't pick it up.
    var needsReasoningSplit: Bool {
        self == .minimaxCN || self == .minimaxIntl
    }
}

// MARK: - Thinking Disable Strategy

enum ThinkingDisableField {
    /// `thinking: { type: "disabled" }` — Doubao, Kimi, DeepSeek
    case thinking
    /// `enable_thinking: false` — Bailian (Qwen)
    case enableThinking
    /// `reasoning_effort: "none"` — Zhipu (GLM)
    case reasoningEffort
    /// `think: false` — Ollama
    case think
}

// MARK: - Provider Config Protocol

protocol LLMProviderConfig: Sendable {
    static var provider: LLMProvider { get }
    static var credentialFields: [CredentialField] { get }

    init?(credentials: [String: String])
    func toCredentials() -> [String: String]
    func toLLMConfig() -> LLMConfig
}
