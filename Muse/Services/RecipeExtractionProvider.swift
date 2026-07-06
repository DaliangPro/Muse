import Foundation

protocol RecipeExtractionProvider: Sendable {
    func extractResults(
        from records: [HistoryRecord],
        recipe: ExtractionRecipe,
        configuration: AssetExtractionConfiguration
    ) async throws -> RecipeExtractionOutput
}

struct RecipeExtractionOutput: Sendable {
    let results: [RecipeExtractionDraft]
    let summary: String?
}

struct RecipeExtractionDraft: Decodable, Sendable {
    let title: String?
    let content: String
    let summary: String?
    let payloadJSON: String?
    let sourceRecordIDs: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case content
        case summary
        case payloadJSON = "payload_json"
        case sourceRecordIDs = "source_record_ids"
    }
}

actor RemoteRecipeExtractionProvider: RecipeExtractionProvider {
    private let clientOverride: (any LLMClient)?

    init(clientOverride: (any LLMClient)? = nil) {
        self.clientOverride = clientOverride
    }

    func extractResults(
        from records: [HistoryRecord],
        recipe: ExtractionRecipe,
        configuration: AssetExtractionConfiguration
    ) async throws -> RecipeExtractionOutput {
        guard !records.isEmpty else {
            throw AssetExtractionError.noSourceRecords
        }

        let provider = KeychainService.selectedAssetExtractionLLMProvider
        if provider == .localQwen, KeychainService.loadAssetExtractionLLMConfig() == nil {
            AppLogger.log("[RecipeExtraction] 本地引擎未运行，按需启动…")
            do {
                try await SenseVoiceServerManager.shared.start()
            } catch {
                AppLogger.log("[RecipeExtraction] 本地引擎按需启动失败: \(String(describing: error))")
            }
        }

        guard let llmConfig = KeychainService.loadAssetExtractionLLMConfig() else {
            throw AssetExtractionError.missingLLMConfig
        }

        let client: any LLMClient = clientOverride ?? LLMProviderRegistry.makeClient(for: provider)
        let messages = Self.promptMessages(
            from: records,
            recipe: recipe,
            configuration: configuration,
            provider: provider
        )
        let raw = try await RemoteAssetExtractionProvider.withTimeout(seconds: 120) {
            try await client.process(text: messages.user, prompt: messages.system ?? "", config: llmConfig)
        }
        return try Self.parse(rawResponse: raw)
    }

    nonisolated static func promptMessages(
        from records: [HistoryRecord],
        recipe: ExtractionRecipe,
        configuration: AssetExtractionConfiguration,
        provider: LLMProvider
    ) -> AssetExtractionPromptMessages {
        let effectiveConfiguration = configuration.adaptedForAssetExtractionProvider(provider)
        let effectiveRecords = Array(records.prefix(effectiveConfiguration.maxRecordCount))
        let input = buildInput(records: effectiveRecords, configuration: effectiveConfiguration)
        let prompt = buildPrompt(recipe: recipe, usesCompactPrompt: provider == .localQwen)
        let parts = prompt.separatedLLMMessages(with: input)
        return AssetExtractionPromptMessages(system: parts.system, user: parts.user)
    }

    private nonisolated static func buildInput(
        records: [HistoryRecord],
        configuration: AssetExtractionConfiguration
    ) -> String {
        let formatter = ISO8601DateFormatter()
        return records.sorted { $0.createdAt < $1.createdAt }.map { record in
            let mode = record.processingMode ?? L("直出", "Direct")
            let text = truncatedText(record.finalText, limit: configuration.maxCharactersPerRecord)
            return """
            [记录]
            id: \(record.id)
            created_at: \(formatter.string(from: record.createdAt))
            processing_mode: \(mode)
            final_text: \(text)
            """
        }.joined(separator: "\n\n")
    }

    private nonisolated static func buildPrompt(
        recipe: ExtractionRecipe,
        usesCompactPrompt: Bool
    ) -> String {
        if usesCompactPrompt {
            return """
            你是 Muse 语料提炼管线的「宽提取」段。严格按当前方案处理输入语料，只输出 JSON。你的输出还会经过独立严审，你的职责是找全：符合方案目标的内容一条都不要漏，边缘情况倾向输出。

            \(recipe.compactPromptBlock)

            规则：只能基于输入记录；每条结果必须有 source_record_ids；不能补充原文没有的信息；输出结构以下方 JSON 为准（忽略方案里的结构描述）；没有符合目标的内容时 results 返回空数组。
            输出：{"results":[{"title":"标题","content":"结果正文","summary":"可为空","payload_json":"{}","source_record_ids":["id"]}],"summary":"一句话概括"}

            输入：
            {text}
            """
        }

        return """
        你是 Muse 语料提炼管线的「宽提取」段。你会收到一批用户真实语音输入记录，请按照“当前提炼方案”处理这批语料。

        你的输出随后会交给独立的严审段按标准逐条把关，所以你的唯一职责是找全：
        - 凡是可能符合方案目标的内容，一条都不要漏；拿不准的边缘候选倾向输出，让严审去判
        - 但找全不等于编造：仍然只能输出原文真实存在的内容

        \(recipe.promptBlock)

        核心边界：
        - 只能基于输入记录工作，禁止编造事实、待办、结论、案例或用户没说过的话
        - 把选定范围内的语料作为一个整体阅读，尤其适用于待办整理、日报、总结和结构提炼
        - 每条结果必须填写 source_record_ids，且只能使用输入里真实存在的 id
        - 如果是总结类结果，可以组织语言，但关键判断必须能回到来源记录
        - 输出结构以下方 JSON 为准；方案里的结构描述仅供理解字段含义
        - 如果输入里没有符合当前方案目标的内容，results 返回空数组

        JSON 结构必须严格符合：
        {
          "results": [
            {
              "title": "简短标题",
              "content": "提炼结果正文",
              "summary": "一句话摘要，可为空字符串",
              "payload_json": "{}",
              "source_record_ids": ["id1"]
            }
          ],
          "summary": "本次提炼概括，可为空字符串"
        }

        字段要求：
        - title：能让用户一眼知道这条结果是什么
        - content：最终展示给用户看的正文
        - summary：辅助摘要；没有就填空字符串
        - payload_json：额外结构化信息，必须是 JSON 字符串；没有就填 "{}"
        - source_record_ids：这条结果引用到的记录 id

        现在开始处理以下语料：
        {text}
        """
    }

    private nonisolated static func truncatedText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "……"
    }

    private nonisolated static func parse(rawResponse: String) throws -> RecipeExtractionOutput {
        let trimmed = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```json\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^```\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ProviderRecipeResponse.self, from: data)
        else {
            throw AssetExtractionError.invalidProviderResponse(String(trimmed.prefix(240)))
        }

        return RecipeExtractionOutput(
            results: decoded.results ?? [],
            summary: decoded.summary
        )
    }
}

private struct ProviderRecipeResponse: Decodable, Sendable {
    let results: [RecipeExtractionDraft]?
    let summary: String?
}
