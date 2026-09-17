import Foundation

enum PolishModelRole: String, CaseIterable, Identifiable, Sendable {
    case light
    case standard

    var id: String { rawValue }
    var title: String {
        self == .light ? L("轻度润色模型", "Light Polish Model") : L("标准润色模型", "Standard Polish Model")
    }
    static func resolve(_ quality: VoicePolishQualityMode?) -> Self {
        quality == .light ? .light : .standard
    }
}

/// 与实际润色一致：单请求、关闭思考；不再把思考开关验证混入连接测试。
enum PolishModelConnectionTester {
    static func test(role: PolishModelRole, config: LLMConfig, client: any LLMClient) async throws {
        let response = try await client.generate(LLMRequest(
            context: .connectivityProbe,
            task: role == .light ? .voicePolishRender : .voicePolishStructured,
            system: "只返回用户提供的文字，不要解释。",
            user: "连接正常",
            options: LLMGenerationOptions(temperature: 0, maxOutputTokens: 64, reasoningPolicy: .disabled)
        ), config: config.withThinkingMode(.disabled))
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse(nil)
        }
    }
}
