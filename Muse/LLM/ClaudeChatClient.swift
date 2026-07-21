import Foundation
import os

actor ClaudeChatClient: LLMClient {

    private let logger = Logger(subsystem: "pro.daliang.muse.llm", category: "ClaudeChatClient")
    private let session: URLSession

    init(session: URLSession = LLMNetworkSession.shared) {
        self.session = session
    }

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = try? LLMEndpointPolicy.normalizedBaseURL(
            rawValue: baseURL,
            provider: .claude
        ) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        if let response = try? await session.bytes(for: request) {
            _ = try? await LLMNetworkSession.readPrefix(response.0, limit: 1)
        }
        logger.info("Claude connection pre-warmed")
    }

    /// Process text through Anthropic Messages API (streaming).
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let promptParts = prompt.separatedLLMMessages(with: trimmedText)

        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: config.baseURL,
            provider: .claude
        )
        let url = try LLMEndpointPolicy.endpoint(
            baseURL: baseURL,
            pathComponents: ["messages"]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = ClaudeRequest(
            model: config.model,
            max_tokens: 4096,
            system: promptParts.system,
            messages: [ClaudeMessage(role: "user", content: promptParts.user)],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("Claude request: \(text.count) chars, model=\(config.model)")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("Claude HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        var parser = ClaudeStreamingParser()
        var decoder = SSEByteStreamDecoder()
        do {
            for try await byte in bytes {
                if let line = try decoder.consume(byte: byte) {
                    try parser.consume(line: line)
                    if parser.isComplete { break }
                }
            }
            if !parser.isComplete, let line = try decoder.finish() {
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
        let result = try parser.finish()

        logger.info("Claude result: \(result.count) chars")

        return result.strippingThinkTags()
    }

    private static func shouldFlushPendingLine(after error: Error) -> Bool {
        !(error is LLMError)
            && !(error is CancellationError)
            && (error as? URLError)?.code != .cancelled
    }
}

// MARK: - Request Types

private struct ClaudeRequest: Encodable, Sendable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [ClaudeMessage]
    let stream: Bool
}

private struct ClaudeMessage: Encodable, Sendable {
    let role: String
    let content: String
}

// MARK: - Stream Response Types

private struct ClaudeStreamEvent: Decodable, Sendable {
    let type: String
    let delta: ClaudeDelta?
}

private struct ClaudeDelta: Decodable, Sendable {
    let text: String?
}

private struct ClaudeStreamingParser: Sendable {
    private var events = SSEEventAccumulator()
    private var result = ""
    private var resultBytes = 0
    private(set) var isComplete = false

    mutating func consume(line: String) throws {
        guard !isComplete else { return }
        for payload in try events.consume(line: line) {
            try consume(payload: payload)
        }
    }

    mutating func finish() throws -> String {
        if !isComplete {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        }
        guard isComplete else {
            throw LLMError.truncatedResponse(result.count)
        }
        guard !result.isEmpty else {
            throw LLMError.emptyResponse(nil)
        }
        return result
    }

    mutating func errorForStreamFailure(_ streamError: Error) -> Error {
        if Task.isCancelled {
            return CancellationError()
        }
        if streamError is CancellationError
            || (streamError as? URLError)?.code == .cancelled
            || streamError is LLMError {
            return streamError
        }
        do {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        } catch {
            return error
        }
        return result.isEmpty ? streamError : LLMError.truncatedResponse(result.count)
    }

    private mutating func consume(payload: String) throws {
        if payload == "[DONE]" {
            isComplete = true
            return
        }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data)
        else { return }

        switch event.type {
        case "content_block_delta":
            guard let text = event.delta?.text, !text.isEmpty else { return }
            let additionalBytes = text.utf8.count
            let maximum = LLMStreamingParser.defaultMaximumResponseBytes
            guard additionalBytes <= maximum - resultBytes else {
                throw LLMError.responseTooLarge(maximum)
            }
            result += text
            resultBytes += additionalBytes
        case "message_stop":
            isComplete = true
        default:
            break
        }
    }
}
