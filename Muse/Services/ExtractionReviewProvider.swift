import Foundation

// 2026-07 语料资产重构批二：两段式管线的第二段「严审」。
// 宽提段只管找全（解决漏），本段拿配方的入库/忽略标准逐条判决（解决滥）——
// 「不漏也不滥」不再押在模型单次发挥上。

/// 严审判决：对宽提产物逐条 keep/drop + 评分 + 理由（理由留档给用户审计）
struct ExtractionReviewVerdict: Decodable, Sendable, Equatable {
    let index: Int
    let keep: Bool
    let score: Double?
    let reason: String?
}

protocol ExtractionReviewProvider: Sendable {
    /// 按配方标准逐条评审宽提产物；返回的判决按 index 对应输入顺序
    func review(
        results: [ExtractionResult],
        recipe: ExtractionRecipe
    ) async throws -> [ExtractionReviewVerdict]
}

actor RemoteExtractionReviewProvider: ExtractionReviewProvider {
    private let clientOverride: (any LLMClient)?

    init(clientOverride: (any LLMClient)? = nil) {
        self.clientOverride = clientOverride
    }

    /// 每批评审的候选上限：一次塞几十条会稀释单条判决的注意力，导致边缘候选摇摆
    /// （实测同一句 88 分保留 vs 40 分砍掉）；批量过大还会让响应超长被截断。8 条兼顾专注与输出长度
    private static let reviewBatchSize = 8

    func review(
        results: [ExtractionResult],
        recipe: ExtractionRecipe
    ) async throws -> [ExtractionReviewVerdict] {
        guard !results.isEmpty else { return [] }

        guard let llmConfig = KeychainService.loadAssetExtractionLLMConfig() else {
            throw AssetExtractionError.missingLLMConfig
        }

        let provider = KeychainService.selectedAssetExtractionLLMProvider
        let client: any LLMClient = clientOverride ?? LLMProviderRegistry.makeClient(for: provider)

        var allVerdicts: [ExtractionReviewVerdict] = []
        var failedBatches = 0
        var totalBatches = 0
        var offset = 0
        while offset < results.count {
            let batch = Array(results[offset..<min(offset + Self.reviewBatchSize, results.count)])
            totalBatches += 1
            do {
                let messages = Self.promptMessages(results: batch, recipe: recipe)
                let raw = try await RemoteAssetExtractionProvider.withTimeout(seconds: 120) {
                    try await client.process(text: messages.user, prompt: messages.system ?? "", config: llmConfig)
                }
                let verdicts = try Self.parse(rawResponse: raw, expectedCount: batch.count)
                // 批内 index 换算回全局 index
                allVerdicts.append(contentsOf: verdicts.map {
                    ExtractionReviewVerdict(index: $0.index + offset, keep: $0.keep, score: $0.score, reason: $0.reason)
                })
            } catch {
                // 单批失败(响应截断/超时)只跳过该批——该批候选由上层按「评审未覆盖」保留,
                // 绝不废掉其余批次的判决(2026-07 修:一批截断曾导致 520 条全体未过筛)
                failedBatches += 1
                DebugFileLogger.log("[提炼严审] 第 \(totalBatches) 批(\(batch.count) 条)评审失败被跳过: \(String(describing: error).prefix(160))")
            }
            offset += Self.reviewBatchSize
        }

        // 全军覆没才算严审失败,交上层整体 fail-open
        if failedBatches == totalBatches {
            throw AssetExtractionError.invalidProviderResponse("all \(totalBatches) review batches failed")
        }
        return allVerdicts
    }

    nonisolated static func promptMessages(
        results: [ExtractionResult],
        recipe: ExtractionRecipe
    ) -> AssetExtractionPromptMessages {
        let prompt = buildPrompt(recipe: recipe)
        let input = buildInput(results: results)
        let parts = prompt.separatedLLMMessages(with: input)
        return AssetExtractionPromptMessages(system: parts.system, user: parts.user)
    }

    private nonisolated static func buildInput(results: [ExtractionResult]) -> String {
        results.enumerated().map { index, result in
            let content = result.content.count > 800
                ? String(result.content.prefix(800)) + "……"
                : result.content
            return """
            [候选 \(index)]
            title: \(result.title)
            content: \(content)
            """
        }.joined(separator: "\n\n")
    }

    private nonisolated static func buildPrompt(recipe: ExtractionRecipe) -> String {
        // 2026-07 重设计：判决标准=配方的统一 Prompt 全文——用户看到并编辑的就是严审生效的
        return """
        你是严格的语料资产评审员。收到的候选来自「宽提取」阶段——它只负责找全，不保证质量。你的唯一职责：按下面的标准逐条判决，砍掉不达标的候选，绝不放水。

        当前配方：\(recipe.name)（\(recipe.recipeDescription)）

        用户对这个配方的完整要求（判决标准，逐条对照）：
        \(recipe.unifiedPrompt)

        判决原则：
        - 逐条独立判决：先对照要求里的「不要输出」，命中即砍；再对照「该保留」的标准，不满足也砍
        - 宁缺毋滥：拿不准就砍；「有点用」不等于达标；不要因为数量少就放水
        - 不许错杀：清晰满足入库标准的候选必须保留
        - score 为 0-100 的达标程度分，砍掉的也要给分
        - reason 一句话点出命中哪条标准，不超过 40 字（输出必须完整，禁止长篇展开）

        输出 JSON，结构必须严格符合：
        {"verdicts":[{"index":0,"keep":true,"score":88,"reason":"判决依据"}]}
        verdicts 必须覆盖每一条候选，index 与输入编号一一对应，不得增删。

        现在开始评审以下候选：
        {text}
        """
    }

    private nonisolated static func parse(
        rawResponse: String,
        expectedCount: Int
    ) throws -> [ExtractionReviewVerdict] {
        let trimmed = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```json\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^```\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ReviewResponse.self, from: data),
              let verdicts = decoded.verdicts
        else {
            throw AssetExtractionError.invalidProviderResponse(String(trimmed.prefix(240)))
        }

        // 只认输入范围内的 index；重复 index 以第一次为准
        var byIndex: [Int: ExtractionReviewVerdict] = [:]
        for verdict in verdicts where verdict.index >= 0 && verdict.index < expectedCount {
            if byIndex[verdict.index] == nil {
                byIndex[verdict.index] = verdict
            }
        }
        return (0..<expectedCount).compactMap { byIndex[$0] }
    }
}

private struct ReviewResponse: Decodable, Sendable {
    let verdicts: [ExtractionReviewVerdict]?
}
