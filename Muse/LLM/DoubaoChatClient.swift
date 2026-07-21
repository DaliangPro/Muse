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
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let promptParts = prompt.separatedLLMMessages(with: trimmedText)

        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: provider,
            localQwenPort: provider == .localQwen ? LLMEndpointPolicy.currentLocalQwenPort : nil
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["chat", "completions"]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let useStreaming = provider != .localQwen
        let disableField = provider.thinkingDisableField
        var messages: [ChatMessage] = []
        if let system = promptParts.system {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: promptParts.user))
        let body = ChatRequest(
            model: config.model,
            messages: messages,
            stream: useStreaming,
            thinking: disableField == .thinking ? ThinkingConfig(type: "disabled") : nil,
            enable_thinking: disableField == .enableThinking ? false : nil,
            reasoning_effort: disableField == .reasoningEffort ? "none" : nil,
            think: disableField == .think ? false : nil,
            reasoning_split: provider.needsReasoningSplit ? true : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        Self.authorizeLocalServiceRequest(&request, provider: provider)

        logger.info("LLM request: \(text.count) chars, endpoint=\(config.model), stream=\(useStreaming)")

        let result: String
        if useStreaming {
            result = try await processStreaming(request: request, model: config.model)
        } else {
            result = try await processNonStreaming(request: request, model: config.model)
        }

        logger.info("LLM result: \(result.count) chars")
        return result.strippingThinkTags()
    }

    static func authorizeLocalServiceRequest(
        _ request: inout URLRequest,
        provider: LLMProvider
    ) {
        guard provider == .localQwen else { return }
        LocalServiceAuth.authorize(&request)
    }

    // MARK: - Streaming (SSE)

    private func processStreaming(request: URLRequest, model: String) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("LLM HTTP \(http.statusCode)")
            DebugFileLogger.log("LLM[\(model)]: HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        var lineCount = 0
        var parser = LLMStreamingParser()
        var decoder = SSEByteStreamDecoder()
        do {
            for try await byte in bytes {
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
            return try parser.finish()
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

    private func processNonStreaming(request: URLRequest, model: String) async throws -> String {
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
            throw LLMError.requestFailed(http.statusCode)
        }

        let data = try await LLMNetworkSession.readCapped(
            bytes,
            limit: LLMStreamingParser.defaultMaximumResponseBytes
        )

        guard let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = json.choices.first?.message.content, !content.isEmpty
        else {
            DebugFileLogger.log("LLM[\(model)]: non-streaming empty; raw bytes=\(min(data.count, 300))")
            throw LLMError.emptyResponse(nil)
        }
        return content
    }
}

// MARK: - Request/Response Types

struct ThinkingConfig: Encodable, Sendable {
    let type: String
}

struct ChatRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let thinking: ThinkingConfig?
    let enable_thinking: Bool?
    let reasoning_effort: String?
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
}

struct CompletionChoice: Decodable, Sendable {
    let message: CompletionMessage
}

struct CompletionMessage: Decodable, Sendable {
    let content: String?
}

// Streaming response (SSE chunks)
struct ChatStreamChunk: Decodable, Sendable {
    let choices: [ChunkChoice]
}

struct ChunkChoice: Decodable, Sendable {
    let delta: ChunkDelta?
    let finish_reason: String?
}

struct ChunkDelta: Decodable, Sendable {
    let content: String?
}

enum LLMError: Error, LocalizedError {
    case invalidURL
    case requestFailed(Int)
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
            switch code {
            case 401: return L("LLM 鉴权失败，请检查 API Key", "LLM auth failed, check API Key")
            case 429: return L("LLM 请求超限或余额不足", "LLM rate limit or insufficient balance")
            case 500, 502, 503: return L("LLM 服务异常 (\(code))", "LLM service error (\(code))")
            default:  return L("LLM 请求失败 (\(code))", "LLM request failed (\(code))")
            }
        case .emptyResponse(let raw):
            _ = raw
            return L("LLM 未返回内容", "LLM returned no content")
        case .truncatedResponse:
            return L("LLM 流式响应提前中断，请重试", "LLM streaming response was truncated; retry")
        case .responseTooLarge:
            return L("LLM 响应超过安全上限", "LLM response exceeded the safety limit")
        }
    }
}
