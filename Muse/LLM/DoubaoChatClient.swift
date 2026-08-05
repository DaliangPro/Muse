import Foundation
import os

actor DoubaoChatClient: LLMClient {

    private let logger = Logger(subsystem: "pro.daliang.muse.llm", category: "DoubaoChatClient")
    private let provider: LLMProvider
    private let session: URLSession

    init(
        provider: LLMProvider = .doubao,
        session: URLSession = LLMNetworkSession.shared
    ) {
        self.provider = provider
        self.session = session
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = try? LLMEndpointPolicy.normalizedBaseURL(
            rawValue: baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        Self.authorizeLocalServiceRequest(&request, provider: provider)
        if let response = try? await session.bytes(for: request) {
            _ = try? await LLMNetworkSession.readPrefix(response.0, limit: 1)
        }
        logger.info("LLM connection pre-warmed")
    }

    /// Process text through Doubao ARK API (OpenAI-compatible streaming).
    /// Returns the full LLM response as a single string.
    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        let result = try await execute(
            text: text,
            prompt: prompt,
            context: context,
            config: config,
            useStreaming: provider != .localQwen,
            maxTokens: nil,
            purpose: .runtime
        )
        LLMThinkingRuntimeState.recordRuntimeEvidence(
            result.evidence,
            provider: provider,
            config: config
        )
        return result.text.strippingThinkTags()
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let trimmedUser = request.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            return LLMResponse(text: request.user, model: config.model)
        }

        let promptParts = LLMRequestBuilder.messages(for: request)
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["chat", "completions"]
        )
        var messages: [ChatMessage] = []
        if let system = promptParts.system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: promptParts.user))

        let capabilities = LLMProviderCapabilityResolver.capabilities(
            provider: provider,
            config: config
        )
        let requestConfig: LLMConfig
        switch request.options.reasoningPolicy {
        case .disabled:
            requestConfig = config.withThinkingMode(.disabled)
        case .low:
            requestConfig = config.withThinkingMode(.enabled)
        case .providerDefault:
            requestConfig = config
        }
        let appliesThinkingControl = capabilities.supportsReasoningControl
            && request.options.reasoningPolicy != .providerDefault

        // generate 的一次调用严格对应一次真实请求；能力字段被拒绝时直接把错误
        // 交还 VoicePolishPipeline，由统一预算决定下一步。
        let result = try await send(
            url: url,
            textLength: request.user.count,
            config: requestConfig,
            messages: messages,
            useStreaming: provider != .localQwen,
            maxTokens: capabilities.supportsDynamicMaxTokens
                ? request.options.maxOutputTokens
                : nil,
            appliesThinkingControl: appliesThinkingControl,
            temperature: capabilities.supportsTemperature
                ? request.options.temperature
                : nil,
            responseFormat: capabilities.supportsJSONMode
                ? request.options.responseFormat
                : .text,
            reasoningPolicy: request.options.reasoningPolicy
        )
        return LLMResponse(text: result.text, model: config.model)
    }

    func probeThinkingMode(config: LLMConfig) async throws -> LLMThinkingProbeEvidence {
        let result = try await execute(
            text: LLMThinkingModeValidator.probeText,
            prompt: "{text}",
            context: .connectivityProbe,
            config: config,
            useStreaming: Self.usesStreamingForThinkingProbe(provider: provider),
            maxTokens: Self.maximumTokensForThinkingProbe(provider: provider),
            purpose: .probe
        )
        return result.evidence
    }

    static func usesStreamingForThinkingProbe(provider: LLMProvider) -> Bool {
        // 百炼部分思考模型只接受流式调用；关闭状态也走流式，才能在固定思考模型
        // 拒绝 false 后用同一传输方式完成基线探测。
        return provider == .bailian
    }

    static func maximumTokensForThinkingProbe(provider: LLMProvider) -> Int? {
        // OpenAI 的部分推理模型拒绝旧式 max_tokens，而兼容端点对
        // max_completion_tokens 的支持又不一致。探测题已要求只返回答案，
        // 因此省略上限字段兼容性最高；响应体仍受客户端硬上限保护。
        provider == .openai ? nil : 1_024
    }

    private func execute(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig,
        useStreaming: Bool,
        maxTokens: Int?,
        purpose: LLMThinkingRequestPurpose
    ) async throws -> LLMExecutionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return LLMExecutionResult(text: text, evidence: .unknown)
        }
        let promptParts = LLMRequestBuilder.messages(
            prompt: prompt,
            text: trimmedText,
            context: context
        )

        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["chat", "completions"]
        )

        var messages: [ChatMessage] = []
        if let system = promptParts.system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: promptParts.user))
        let signature = LLMConnectivitySignature(provider: provider, config: config)
        if purpose == .runtime,
           LLMThinkingRuntimeState.preference(for: signature) == .omitControl {
            return try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: false
            )
        }

        do {
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: true
            )
            if purpose == .probe,
               provider.thinkingRequestField(for: config.model).isExplicitlyControllable {
                LLMThinkingRuntimeState.clearPreference(for: signature)
            }
            return result
        } catch let error as LLMError where
            provider.thinkingRequestField(for: config.model).isExplicitlyControllable
                && error.isThinkingModeRejection {
            // 模型的能力可能比服务商协议更窄：例如固定思考模型会拒绝显式开关，
            // 非思考模型则可能拒绝整个控制字段。退回基础请求后由响应证据判定实际状态。
            logger.info("LLM thinking control rejected; retrying without control field")
            let result = try await send(
                url: url,
                textLength: text.count,
                config: config,
                messages: messages,
                useStreaming: useStreaming,
                maxTokens: maxTokens,
                appliesThinkingControl: false
            )
            LLMThinkingRuntimeState.rememberOmittedControl(for: signature)
            return result
        }
    }

    private func send(
        url: URL,
        textLength: Int,
        config: LLMConfig,
        messages: [ChatMessage],
        useStreaming: Bool,
        maxTokens: Int?,
        appliesThinkingControl: Bool,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat = .text,
        reasoningPolicy: ReasoningPolicy = .providerDefault
    ) async throws -> LLMExecutionResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Self.makeChatRequest(
            provider: provider,
            config: config,
            messages: messages,
            stream: useStreaming,
            maxTokens: maxTokens,
            appliesThinkingControl: appliesThinkingControl,
            temperature: temperature,
            responseFormat: responseFormat,
            reasoningPolicy: reasoningPolicy
        ))
        Self.authorizeLocalServiceRequest(&request, provider: provider)

        logger.info(
            "LLM request: \(textLength) chars, endpoint=\(config.model), stream=\(useStreaming), thinking=\(config.thinkingMode.rawValue), controlled=\(appliesThinkingControl)"
        )

        let requestStartedAt = ContinuousClock.now
        let result = useStreaming
            ? try await processStreaming(
                request: request,
                model: config.model,
                requestStartedAt: requestStartedAt
            )
            : try await processNonStreaming(
                request: request,
                model: config.model,
                requestStartedAt: requestStartedAt
            )
        let controlAccepted = appliesThinkingControl
            && provider.thinkingRequestField(for: config.model).isExplicitlyControllable
        logger.info("LLM result: \(result.text.count) chars")
        return LLMExecutionResult(
            text: result.text,
            evidence: result.evidence.withControlAccepted(controlAccepted)
        )
    }

    static func makeChatRequest(
        provider: LLMProvider,
        config: LLMConfig,
        messages: [ChatMessage],
        stream: Bool,
        maxTokens: Int?,
        appliesThinkingControl: Bool = true,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat = .text,
        reasoningPolicy: ReasoningPolicy = .providerDefault
    ) -> ChatRequest {
        let thinkingField = provider.thinkingRequestField(for: config.model)
        let thinkingEnabled = config.thinkingMode.isEnabled
        let reasoningEffort: String
        if !thinkingEnabled {
            reasoningEffort = "none"
        } else if reasoningPolicy == .low {
            reasoningEffort = "low"
        } else {
            reasoningEffort = "medium"
        }
        return ChatRequest(
            model: config.model,
            messages: messages,
            stream: stream,
            max_tokens: maxTokens,
            temperature: temperature,
            response_format: responseFormat == .jsonObject
                ? ChatResponseFormat(type: "json_object")
                : nil,
            thinking: appliesThinkingControl && thinkingField == .thinking
                ? ThinkingConfig(type: thinkingEnabled ? "enabled" : "disabled")
                : nil,
            enable_thinking: appliesThinkingControl && thinkingField == .enableThinking
                ? thinkingEnabled
                : nil,
            reasoning_effort: appliesThinkingControl && thinkingField == .reasoningEffort
                ? reasoningEffort
                : nil,
            reasoning: appliesThinkingControl && thinkingField == .reasoningObject
                ? ReasoningConfig(effort: reasoningEffort)
                : nil,
            think: appliesThinkingControl && thinkingField == .think ? thinkingEnabled : nil,
            reasoning_split: provider.needsReasoningSplit ? true : nil
        )
    }

    static func authorizeLocalServiceRequest(
        _ request: inout URLRequest,
        provider: LLMProvider
    ) {
        guard provider == .localQwen else { return }
        LocalServiceAuth.authorize(&request)
    }

    // MARK: - Streaming (SSE)

    private func processStreaming(
        request: URLRequest,
        model: String,
        requestStartedAt: ContinuousClock.Instant
    ) async throws -> LLMExecutionResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "LLM[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }

        var lineCount = 0
        var didRecordFirstByte = false
        var parser = LLMStreamingParser()
        var decoder = SSEByteStreamDecoder()
        do {
            for try await byte in bytes {
                if !didRecordFirstByte {
                    didRecordFirstByte = true
                    DebugFileLogger.log(
                        "LLM[\(model)]: ttft_ms=\(Self.milliseconds(ContinuousClock.now - requestStartedAt)) transport=stream"
                    )
                }
                if let line = try decoder.consume(byte: byte) {
                    lineCount += 1
                    try parser.consume(line: line)
                    if parser.isComplete { break }
                }
            }
            if !parser.isComplete, let line = try decoder.finish() {
                lineCount += 1
                try parser.consume(line: line)
            }
        } catch {
            if Self.shouldFlushPendingLine(after: error) {
                do {
                    if let line = try decoder.finish() {
                        try parser.consume(line: line)
                    }
                } catch {
                    throw parser.errorForStreamFailure(error)
                }
            }
            throw parser.errorForStreamFailure(error)
        }

        do {
            let text = try parser.finish()
            return LLMExecutionResult(
                text: text,
                evidence: LLMThinkingProbeEvidence(
                    reportedMode: nil,
                    reasoningObserved: parser.reasoningObserved ? true : nil
                )
            )
        } catch {
            DebugFileLogger.log("LLM[\(model)]: stream incomplete lines=\(lineCount)")
            throw error
        }
    }

    private static func shouldFlushPendingLine(after error: Error) -> Bool {
        !(error is LLMError)
            && !(error is CancellationError)
            && (error as? URLError)?.code != .cancelled
    }

    // MARK: - Non-streaming (single JSON response)

    private func processNonStreaming(
        request: URLRequest,
        model: String,
        requestStartedAt: ContinuousClock.Instant
    ) async throws -> LLMExecutionResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            let errorData = try await LLMNetworkSession.readPrefix(bytes, limit: 512)
            let errorBody = LLMNetworkSession.sanitizedErrorBody(errorData, limit: 512)
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log(
                "LLM[\(model)]: HTTP \(http.statusCode), retained error bytes=\(errorBody.utf8.count)"
            )
            throw LLMError.requestRejected(http.statusCode, errorBody)
        }
        DebugFileLogger.log(
            "LLM[\(model)]: ttft_ms=\(Self.milliseconds(ContinuousClock.now - requestStartedAt)) transport=nonstream"
        )

        let data = try await LLMNetworkSession.readCapped(
            bytes,
            limit: LLMStreamingParser.defaultMaximumResponseBytes
        )

        guard let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = json.choices.first?.message.content, !content.isEmpty else {
            DebugFileLogger.log("LLM[\(model)]: non-streaming empty; raw bytes=\(min(data.count, 300))")
            throw LLMError.emptyResponse(nil)
        }
        guard !json.hitOutputTokenLimit else {
            throw LLMError.truncatedResponse(content.count)
        }
        return LLMExecutionResult(text: content, evidence: json.thinkingEvidence)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Request/Response Types

private struct LLMExecutionResult: Sendable {
    let text: String
    let evidence: LLMThinkingProbeEvidence
}

struct ThinkingConfig: Encodable, Sendable {
    let type: String
}

struct ReasoningConfig: Encodable, Sendable {
    let effort: String
}

struct ChatResponseFormat: Encodable, Sendable {
    let type: String
}

struct ChatRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let max_tokens: Int?
    let temperature: Double?
    let response_format: ChatResponseFormat?
    let thinking: ThinkingConfig?
    let enable_thinking: Bool?
    let reasoning_effort: String?
    let reasoning: ReasoningConfig?
    let think: Bool?
    let reasoning_split: Bool?
}

struct ChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

// Non-streaming response
struct ChatCompletionResponse: Decodable, Sendable {
    let choices: [CompletionChoice]
    let usage: ChatUsage?
    let muse_thinking_mode: String?

    var thinkingEvidence: LLMThinkingProbeEvidence {
        let message = choices.first?.message
        let reportedMode = muse_thinking_mode.flatMap(LLMThinkingMode.init(rawValue:))
        let observed: Bool?
        if message?.reasoningObserved == true
            || (usage?.completion_tokens_details?.reasoning_tokens ?? 0) > 0 {
            observed = true
        } else if usage?.completion_tokens_details?.reasoning_tokens == 0 {
            observed = false
        } else {
            observed = nil
        }
        return LLMThinkingProbeEvidence(
            reportedMode: reportedMode,
            reasoningObserved: observed
        )
    }

    var hitOutputTokenLimit: Bool {
        choices.contains {
            LLMCompletionTermination.hitOutputTokenLimit($0.finish_reason)
        }
    }
}

struct CompletionChoice: Decodable, Sendable {
    let message: CompletionMessage
    let finish_reason: String?
}

struct CompletionMessage: Decodable, Sendable {
    let content: String?
    let reasoningContent: String?
    let reasoningDetailsPresent: Bool

    var reasoningObserved: Bool {
        !(reasoningContent ?? "").isEmpty
            || reasoningDetailsPresent
            || (content?.contains("<think>") ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case reasoning
        case thinking
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        let primaryReasoning = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        // 不同兼容端点可能把这些字段返回成字符串、数组或对象。
        // 非字符串结构不应让正常的 content 一并解码失败。
        let fallbackReasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        let thinking = try? container.decodeIfPresent(String.self, forKey: .thinking)
        reasoningContent = primaryReasoning ?? fallbackReasoning ?? thinking
        let reasoningDetails = try? container.decodeIfPresent(
            [ReasoningDetailMarker].self,
            forKey: .reasoningDetails
        )
        reasoningDetailsPresent = !(reasoningDetails ?? []).isEmpty
    }
}

struct ChatUsage: Decodable, Sendable {
    let completion_tokens_details: CompletionTokenDetails?
}

struct CompletionTokenDetails: Decodable, Sendable {
    let reasoning_tokens: Int?
}

// Streaming response (SSE chunks)
struct ChatStreamChunk: Decodable, Sendable {
    let choices: [ChunkChoice]
    let usage: ChatUsage?
}

struct ChunkChoice: Decodable, Sendable {
    let delta: ChunkDelta?
    let finish_reason: String?
}

struct ChunkDelta: Decodable, Sendable {
    let content: String?
    let reasoning_content: String?
    let reasoning: String?
    let thinking: String?
    let reasoning_details: [ReasoningDetailMarker]?

    var reasoningObserved: Bool {
        !(reasoning_content ?? "").isEmpty
            || !(reasoning ?? "").isEmpty
            || !(thinking ?? "").isEmpty
            || !(reasoning_details ?? []).isEmpty
    }
}

struct ReasoningDetailMarker: Decodable, Sendable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

enum LLMError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Int)
    case requestRejected(Int, String)
    case emptyResponse(String?)
    case truncatedResponse(Int)
    case responseTooLarge(Int)
    /// REPAIR_PLAN J12：会话级硬超时（底层 30s 是无数据间隔语义，慢速涓流可绕过）
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("LLM 地址无效", "Invalid LLM URL")
        case .timedOut:
            return L("LLM 处理超时", "LLM processing timed out")
        case .requestFailed(let code):
            return Self.requestFailureDescription(code: code)
        case .requestRejected(let code, _):
            return Self.requestFailureDescription(code: code)
        case .emptyResponse(let raw):
            _ = raw
            return L("LLM 未返回内容", "LLM returned no content")
        case .truncatedResponse:
            return L("LLM 流式响应提前中断，请重试", "LLM streaming response was truncated; retry")
        case .responseTooLarge:
            return L("LLM 响应超过安全上限", "LLM response exceeded the safety limit")
        }
    }

    var isThinkingModeRejection: Bool {
        guard case .requestRejected(let code, let message) = self,
              code == 400 || code == 422
        else { return false }
        let normalized = message.lowercased()
        let markers = [
            "thinking",
            "reasoning",
            "enable_thinking",
            "reasoning_effort",
            "\"think\"",
            "'think'",
        ]
        let rejectionMarkers = [
            "unsupported",
            "not supported",
            "does not support",
            "invalid",
            "unknown parameter",
            "unrecognized",
            "not allowed",
            "not permitted",
            "cannot",
            "can't",
            "always enabled",
            "only supports",
            "expected",
            "should be",
            "must be",
        ]
        return markers.contains { normalized.contains($0) }
            && rejectionMarkers.contains { normalized.contains($0) }
    }

    private static func requestFailureDescription(code: Int) -> String {
        switch code {
        case 401:
            return L("LLM 鉴权失败，请检查 API Key", "LLM auth failed, check API Key")
        case 429:
            return L("LLM 请求超限或余额不足", "LLM rate limit or insufficient balance")
        case 500, 502, 503:
            return L("LLM 服务异常 (\(code))", "LLM service error (\(code))")
        default:
            return L("LLM 请求失败 (\(code))", "LLM request failed (\(code))")
        }
    }
}
