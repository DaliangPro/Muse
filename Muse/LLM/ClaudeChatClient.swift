import Foundation
import os

actor ClaudeChatClient: LLMClient {

    private let logger = Logger(subsystem: "pro.daliang.muse.llm", category: "ClaudeChatClient")

    /// Pre-establish TCP+TLS connection so the first real request skips handshake.
    func warmUp(baseURL: String) async {
        guard let url = URL(string: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
        logger.info("Claude connection pre-warmed to \(baseURL)")
    }

    /// Process text through Anthropic Messages API (streaming).
    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return text }
        let promptParts = prompt.separatedLLMMessages(with: trimmedText)

        guard let url = URL(string: "\(config.baseURL)/messages") else {
            throw LLMError.invalidURL
        }

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

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.requestFailed(0)
        }
        guard http.statusCode == 200 else {
            logger.error("Claude HTTP \(http.statusCode)")
            throw LLMError.requestFailed(http.statusCode)
        }

        // Parse SSE stream (Anthropic format)
        var result = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data)
            else { continue }

            switch event.type {
            case "content_block_delta":
                if let delta = event.delta, let text = delta.text {
                    result += text
                }
            case "message_stop":
                break
            default:
                continue
            }
        }

        logger.info("Claude result: \(result.count) chars")

        return result.strippingThinkTags()
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
