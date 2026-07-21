import Foundation

struct AssetExtractionPromptMessages: Equatable, Sendable {
    let system: String?
    let user: String

    var combinedForDisplay: String {
        [
            "SYSTEM MESSAGE（系统规则）",
            system ?? "",
            "",
            "USER MESSAGE（输入语料）",
            user
        ].joined(separator: "\n")
    }
}

actor RemoteAssetExtractionProvider: AssetExtractionProvider {

    /// 测试注入口：nil 时按所选厂商从注册表创建
    private let clientOverride: (any LLMClient)?

    init(clientOverride: (any LLMClient)? = nil) {
        self.clientOverride = clientOverride
    }

    func extractAssets(
        from records: [HistoryRecord],
        configuration: AssetExtractionConfiguration
    ) async throws -> AssetExtractionResult {
        guard !records.isEmpty else {
            throw AssetExtractionError.noSourceRecords
        }
        let provider = KeychainService.selectedAssetExtractionLLMProvider

        // REPAIR_PLAN H1 改进①：选了本地 Qwen 而本地引擎未运行时按需拉起
        // 并等待就绪（start 内部有健康检查），不再要求用户重启应用
        if provider == .localQwen, KeychainService.loadAssetExtractionLLMConfig() == nil {
            AppLogger.log("[AssetExtraction] 本地引擎未运行，按需启动…")
            do {
                try await SenseVoiceServerManager.shared.start()
            } catch {
                AppLogger.log("[AssetExtraction] 本地引擎按需启动失败: \(String(describing: error))")
            }
        }

        guard let llmConfig = KeychainService.loadAssetExtractionLLMConfig() else {
            throw AssetExtractionError.missingLLMConfig
        }
        let client: any LLMClient = clientOverride ?? LLMProviderRegistry.makeClient(for: provider)

        let messages = Self.promptMessages(
            from: records,
            configuration: configuration,
            provider: provider
        )
        return try await requestAndParse(
            client: client,
            input: messages.user,
            prompt: messages.system ?? "",
            config: llmConfig
        )
    }

    nonisolated static func promptMessages(
        from records: [HistoryRecord],
        configuration: AssetExtractionConfiguration,
        provider: LLMProvider
    ) -> AssetExtractionPromptMessages {
        let effectiveConfiguration = configuration.adaptedForAssetExtractionProvider(provider)
        let effectiveRecords = Array(records.prefix(effectiveConfiguration.maxRecordCount))
        let input = buildInput(records: effectiveRecords, configuration: effectiveConfiguration)
        let prompt = buildPrompt(configuration: effectiveConfiguration, usesCompactPrompt: provider == .localQwen)
        let parts = prompt.separatedLLMMessages(with: input)
        return AssetExtractionPromptMessages(system: parts.system, user: parts.user)
    }

    /// 单次模型调用的硬超时（改造方案 #6）：大批量输入时模型可能长时间无响应，
    /// 不再让提炼无限挂起
    private static let requestTimeoutSeconds: Double = 120

    /// 请求 + 解析；坏 JSON 自动带纠错指令重试一次（REPAIR_PLAN H1 遗留①）。
    /// 本地小模型干严格 JSON 任务是最高频故障点，一次失手不再让整批提炼白跑
    func requestAndParse(
        client: any LLMClient,
        input: String,
        prompt: String,
        config: LLMConfig
    ) async throws -> AssetExtractionResult {
        let raw = try await Self.withTimeout(seconds: Self.requestTimeoutSeconds) {
            try await client.process(text: input, prompt: prompt, config: config)
        }
        do {
            return try parse(rawResponse: raw)
        } catch {
            AppLogger.log("[AssetExtraction] 响应不是合法 JSON，带纠错指令重试一次")
            let correctedPrompt = prompt + "\n\n注意：你上一次的输出不是合法 JSON，解析失败。这次必须严格只输出符合上述结构的 JSON 本体，禁止 markdown 代码块、禁止任何解释文字。"
            let retryRaw = try await Self.withTimeout(seconds: Self.requestTimeoutSeconds) {
                try await client.process(text: input, prompt: correctedPrompt, config: config)
            }
            return try parse(rawResponse: retryRaw)
        }
    }

    /// 统一使用不会等待底层任务配合 cancellation 的硬超时工具。
    static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await AsyncTimeout.throwingValue(
            .seconds(seconds),
            timeoutError: AssetExtractionError.timeout(Int(seconds)),
            operation: operation
        )
    }

    private nonisolated static func buildInput(records: [HistoryRecord], configuration: AssetExtractionConfiguration) -> String {
        let formatter = ISO8601DateFormatter()
        return records.map { record in
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

    private nonisolated static func truncatedText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "……"
    }

    private nonisolated static func buildPrompt(configuration: AssetExtractionConfiguration, usesCompactPrompt: Bool) -> String {
        if configuration.recipeID == ExtractionRecipe.quoteAssetsID {
            return buildQuotePrompt(configuration: configuration, usesCompactPrompt: usesCompactPrompt)
        }
        if usesCompactPrompt {
            return buildCompactPrompt(configuration: configuration)
        }
        return """
        你是 Muse 的“创作者语料资产候选提炼器”。你会收到一批用户真实输入记录，请只从这些记录中摘取可能服务内容创作的候选素材，最终是否入库由用户判断。

        \(configuration.recipe.promptBlock)

        核心边界：
        - 这是“提炼/摘取”，不是回答、总结、改写、润色或二次创作
        - 候选的 content 必须优先使用原始 final_text 中连续出现的原文片段；可以裁掉片段边界处的多余空白和标点，但不要删改口误或重写表达
        - title 可以是简短标签；summary/reason 可以解释价值；但用户详情页第一眼看到的 content 必须是原始输入本身
        - 禁止替用户回答问题，禁止把问题扩写成答案，禁止把观点总结成用户没说过的新观点，禁止根据原文“创作”金句
        - 如果某条内容需要你概括后才像资产，说明它不是合格候选，不要输出

        质量判定原则：
        - 先判断是否是原文资产，再判断资产类型，最后判断 A/B 等级
        - 宁可少，不要把每一句话都放进候选；普通句子不是资产
        - 低质量：临时产品反馈、操作指令、测试吐槽、情绪宣泄、依赖“这个/它/上面/下面”等上下文才能理解的半句话，不要输出
        - 金句必须短、准、有记忆点，通常带反差、判断、节奏或传播性；只是不长的句子，不等于金句
        - 好观点必须有清晰判断或认知增量；只是描述现象、表达不满、说“这个不对”，不等于好观点

        任务要求：
        1. 只能基于输入内容提炼，禁止编造
        2. 只输出严格 JSON，不要输出 markdown，不要解释
        3. `source_record_ids` 只能填写输入里真实存在的 id
        4. 每条结果的 content 都必须能在对应 source_record_ids 的 final_text 中找到原文依据
        5. 不要过度保守：A 级必须宁缺毋滥，B 级可以保留“可能符合标准、值得用户判断”的候选
        6. 候选等级必须明确输出 A 或 B；C 级及以下不要输出；不确定是否有价值但具备创作潜力时标为 B
        7. 如果下面用户规则与“禁止生成、content 必须来自原文”冲突，以本核心边界为准

        提炼目标：
        - question：好问题。只摘取用户原文里真实提出的问题或困惑；不要回答它
        - viewpoint：好观点。只摘取用户原文里真实表达过的判断、立场、洞察或价值观；不要替用户总结新观点
        - framework：表达框架。只摘取用户原文里已经说出的结构化表达、步骤、判断流程或话术组织方式；不要替用户归纳“三步法”
        - case_material：案例素材。只摘取用户原文里真实出现的人物、事件、场景、案例、类比或具体经历；不要把普通观点包装成案例
        - quote：金句短句。只摘取用户原文里已经说出的高密度短句；不要根据原文重新创作金句

        字段规则：
        - question 类型：title 是简短问题标题；content 必须是原文中的问题本身或包含问题的原文片段，不能写答案、建议或任何答题类内容。
        - viewpoint 类型：title 是简短标签；content 必须是原文中的观点句或观点段落，不能只写你总结后的观点。
        - framework 类型：title 是简短标签；content 必须是原文里已经出现的结构/步骤/流程/话术，不能把零散内容归纳成框架。
        - case_material 类型：title 是简短标签；content 必须是原文里的具体案例/场景/经历，不能虚构人物和情节。
        - quote 类型：title 可以等于 content；content 必须是原文中已经出现的短句，不能改写成更像金句的句子。

        过滤要求：
        - 不要提炼低信息量寒暄
        - 不要提炼明显噪声、口头填充或乱码
        - 不要重复表达同一条内容
        - 不要把普通记录存档伪装成候选资产；B 级只能留“有明确潜力”的候选，不能当作垃圾桶
        \(configuration.ruleConfig.promptBlock)

        JSON 结构必须严格符合；字段名 `assets` 表示“候选资产”，不是正式入库资产：
        {
          "assets": [
            {
              "type": "question",
              "grade": "A",
              "title": "简短标题",
              "content": "来自原始 final_text 的原文摘录",
              "summary": "一句话辅助摘要，可为空字符串",
              "reason": "为什么这条值得沉淀",
              "scenes": ["标题选题", "开头钩子"],
              "audiences": ["内容创作者", "个人IP"],
              "rule_hit": "命中的提炼规则",
              "keywords": ["关键词1", "关键词2"],
              "source_record_ids": ["id1"]
            }
          ],
          "ignored_count": 0,
          "summary": {
            "total_inputs": 50,
            "candidate_count": 4,
            "a_count": 2,
            "b_count": 2
          }
        }

        本次提炼约束：
        - 最多参考 \(configuration.maxRecordCount) 条记录
        - 按用户配置的类型优先方向判断与排序，但不要压制其他明确有价值的资产类型
        - 如果输入里没有具备创作价值的内容，assets 返回空数组

        现在开始提炼以下语料：
        {text}
        """
    }

    private nonisolated static func buildQuotePrompt(
        configuration: AssetExtractionConfiguration,
        usesCompactPrompt: Bool
    ) -> String {
        let customPrompt = configuration.ruleConfig.customPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = customPrompt.isEmpty ? QuoteExtractionPromptStore.defaultPrompt : customPrompt
        let outputExample = usesCompactPrompt
            ? #"{"assets":[{"type":"quote","grade":"A","title":"标题","content":"原文短句","summary":"","reason":"值得沉淀的原因","scenes":["使用场景"],"audiences":[],"rule_hit":"金句","keywords":[],"source_record_ids":["id"]}],"ignored_count":0,"summary":{"total_inputs":0,"candidate_count":0,"a_count":0,"b_count":0}}"#
            : """
            {
              "assets": [
                {
                  "type": "quote",
                  "grade": "A",
                  "title": "可以等于金句本身的短标题",
                  "content": "来自 final_text 的原文连续短句",
                  "summary": "",
                  "reason": "为什么这句话值得沉淀",
                  "scenes": ["标题", "结尾", "口播高光"],
                  "audiences": [],
                  "rule_hit": "金句",
                  "keywords": [],
                  "source_record_ids": ["id1"]
                }
              ],
              "ignored_count": 0,
              "summary": {
                "total_inputs": 50,
                "candidate_count": 1,
                "a_count": 1,
                "b_count": 0
              }
            }
            """

        return """
        你是 Muse 的“金句候选提炼器”。你会收到一批用户真实语音输入记录；最终是否入库、是否二次编辑由用户决定。

        核心任务：
        \(prompt)

        必须遵守：
        - 只提炼 type=quote 的金句候选，不输出其他类型。
        - content 必须是某条 final_text 中连续出现的原文片段。
        - 可以裁掉片段边界处的多余空白和标点，但不能改写、润色、总结、拔高或创作。
        - title、summary、reason 可以辅助说明，但用户真正入库的是 content。
        - 金句不是“比较短的一句话”；必须能被单独摘出来复用。
        - A 级金句必须同时满足：独立完整、原文连续、有判断密度、有复用场景。
        - B 级金句候选必须已经在原文里具备清晰判断、反差或方法论，只是口语、长度或上下文边界还需要用户判断和二次编辑；内部产品、课程、交付和功能决策不能因为“有点方法论”就进入 B；案例叙述、场景解释、举例段落不能因为“生动”就进入 B。
        - 独立完整的硬标准：content 本身必须包含明确讨论对象、判断对象或核心概念；不了解原始对话的人读完不能追问“它是什么？”“他是谁？”“他们是谁？”“这句话是什么？”“这个指什么？”“这个增强回路是什么？”“和什么一样？”“加分项指什么？”。
        - 如果一句判断依赖前文语境，只有能从同一条 final_text 连续截取到“必要上下文 + 判断句”时才输出；否则不要输出，也不要补写上下文。
        - 带“他们、也是一样、这句话、这件事、这个增强回路、这种方式、换一个、它就没有意义、他就没有意义”等承接表达，但没有在 content 里交代对象的句子不要输出，不能标 B。
        - 例如“你改变他们，很难代价会很大。最快的方式就是换一个”不是合格金句，因为读者不知道“他们”是谁。
        - 例如“赚钱也是一样，你看不到滞后性，很容易对你的生意就产生误判”不是合格金句，因为“也是一样”依赖前文类比。
        - 例如“但是创业了七年，我才明白这句话是大错特错纯纯的扯蛋”不是合格金句，因为读者不知道“这句话”是哪句话；情绪强烈不等于对象明确。
        - 价值硬标准：有用的信息不等于金句。content 必须具备对外传播价值，或至少具备值得用户二次编辑的高潜判断、反差、方法论。
        - 局部方案批评不是金句：对某个脚本、案例、模型、方法、方案、增强回路的局部评价，只有在 content 里交代清楚对象并具备普适判断时才可保留。
        - 例如“百分之九十九的生意都能通用这个增强回路，他就没有意义了”不是金句，因为“这个增强回路/他”依赖具体方案上下文，本质是局部方法批评。
        - 案例叙述不是金句：一个片段即使能解释概念、举例生动，也必须先压缩成原文里已经出现的独立判断句，否则不要输出，不能标 B。
        - 例如“家庭是个系统。那有些家庭的目标就是：我孩子一定要考上清华、北大。我天天鸡娃，哪怕鸡飞狗跳。他的成绩也必须上去”不是金句，因为这是案例/场景叙述，不是可单独传播的判断句。
        - 对标、方法、流程、策略不是天然淘汰，也不是天然保留；只有当它已经脱离具体项目语境，并对内容创作、面向读者的商业洞察或个人成长有可迁移价值时，才允许作为 B 级候选。
        - 产品决策硬排除：凡是在讨论自己的产品、课程、交付方式、功能设计、页面交互、提炼流程、价格包装、知识库形态、社群服务、竞品拆解或内部内容诊断，默认都不是金句。
        - 不要把“标品”“零边际成本”“用户自定义提炼什么”“价值感不够”“课程平平无奇”“整段看才有结构”这类产品/课程判断提炼成金句。
        - 内部产品配置、项目执行建议、团队协作安排、课程交付承诺默认不是金句；只有被原文表达成普适洞察、强反差判断或可传播表达时才允许输出。
        - 判断密度至少命中一种：清晰判断、反差结构、因果洞察、价值排序、边界定义、方法论表达、压缩过的经验结论。
        - 对象明确的价值排序句可以判 A，例如“X 的前提是 Y”“先 X，才 Y”。
        - 口水话、顺口话、普通陈述、短但平的句子、操作指令、产品测试、临时吐槽、流水账、上下文不完整或对象不清的半句话不要输出。
        - 例如“我认为它应该是咱们的一个加分项，而不是一个承诺和保证”不是合格金句，因为读者不知道“它”和“加分项”具体指什么。
        - 只有情绪没有认知增量的句子不要输出；只是“说得通”不等于金句。
        - grade 只能是 A 或 B；A 表示可以直接当标题/结尾/海报文案使用，B 表示已经有明显金句潜力但需要用户判断。
        - B 是高潜素材，不是普通句子、有用句子、案例段落、解释段落、铺垫段落、内部工作建议或产品决策的收纳池；如果只是“可能有点用”，不要输出。
        - 举例说明、生活案例、故事片段、场景解释、背景铺垫、数据钩子、转场句、提问引子、针对某个具体稿件/案例/模型/方案/增强回路的局部批评默认不要输出；除非 content 本身已经是原文里完整的金句判断。
        - source_record_ids 只能填写输入中真实存在的 id。
        - 如果没有合格金句，assets 返回空数组。

        只输出严格 JSON，不要 markdown，不要解释。JSON 结构：
        \(outputExample)

        本次提炼约束：
        - 最多参考 \(configuration.maxRecordCount) 条记录

        输入：
        {text}
        """
    }

    private nonisolated static func buildCompactPrompt(configuration: AssetExtractionConfiguration) -> String {
        """
        你是 Muse 的语料资产候选提炼器。只基于输入记录摘取候选素材，禁止编造。最终是否入库由用户判断。

        \(configuration.recipe.compactPromptBlock)

        核心边界：
        - 提炼不是回答、总结、改写、润色或创作
        - content 必须是 final_text 中连续出现的原文片段；title/summary/reason 才能做辅助说明；不要删改口误或重写表达
        - 禁止回答问题、替用户总结观点、归纳用户没说出的框架、创作用户没说过的金句
        - 如果需要概括后才像资产，就不要输出
        - 宁可少，不要把每一句话都放进候选；普通句子不是资产
        - 临时产品反馈、操作指令、测试吐槽、情绪宣泄、依赖上下文的半句话不要输出
        - 金句必须短、准、有记忆点，通常带反差、判断、节奏或传播性；只是不长不代表是金句

        目标类型：
        - question 好问题：原文真实提出的问题或困惑，不要回答
        - viewpoint 好观点：原文真实表达过的判断、立场、洞察或价值观，不要代总结
        - framework 表达框架：原文已经说出的结构、步骤、流程或话术组织，不要代归纳
        - case_material 案例素材：原文真实出现的场景、故事、类比、例子
        - quote 金句短句：原文已经说出的高密度短句，不要改写创作

        等级：
        - A：宁缺毋滥，离开原文也能独立复用
        - B：可能符合标准，有潜力，值得用户判断
        - C 及以下不要输出；grade 只能是 A 或 B

        规则：
        - 只能输出严格 JSON，不要 markdown，不要解释
        - source_record_ids 只能填输入里的真实 id
        - content 必须能在对应 source_record_ids 的 final_text 中找到原文依据
        - 不要寒暄、噪声、乱码、重复、普通流水账
        - question 的 content 写原文问题，不写答案；quote 的 content 不允许是你生成的金句
        - 若用户规则与“禁止生成、content 必须来自原文”冲突，以本规则为准
        \(configuration.ruleConfig.compactPromptBlock)

        输出结构：
        {"assets":[{"type":"question","grade":"A","title":"标题","content":"原文摘录","summary":"","reason":"值得沉淀的原因","scenes":["场景"],"audiences":["人群"],"rule_hit":"命中规则","keywords":["关键词"],"source_record_ids":["id"]}],"ignored_count":0,"summary":{"total_inputs":0,"candidate_count":0,"a_count":0,"b_count":0}}

        约束：
        - 最多参考 \(configuration.maxRecordCount) 条记录
        - 没有具备创作价值的内容时 assets 返回空数组

        输入：
        {text}
        """
    }

    private func parse(rawResponse: String) throws -> AssetExtractionResult {
        let trimmed = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```json\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^```\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ProviderResponse.self, from: data)
        else {
            throw AssetExtractionError.invalidProviderResponse(String(trimmed.prefix(240)))
        }

        return AssetExtractionResult(
            assets: decoded.assets ?? [],
            ignoredCount: decoded.ignoredCount ?? 0,
            summary: decoded.summary ?? .empty
        )
    }
}

private struct ProviderResponse: Decodable, Sendable {
    let assets: [AssetExtractionCandidate]?
    let ignoredCount: Int?
    let summary: AssetExtractionSummary?

    enum CodingKeys: String, CodingKey {
        case assets
        case ignoredCount = "ignored_count"
        case summary
    }
}
