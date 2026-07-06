import Foundation

enum AssetCandidateQuantity: String, Codable, CaseIterable, Sendable {
    case highValueOnly
    case balanced
    case moreCandidates

    var title: String {
        switch self {
        case .highValueOnly:
            return L("只留高价值", "High value only")
        case .balanced:
            return L("平衡提炼", "Balanced")
        case .moreCandidates:
            return L("多给候选", "More candidates")
        }
    }

    var promptInstruction: String {
        switch self {
        case .highValueOnly:
            return "输出倾向从严：优先只输出 A 级；只有明显接近 A、且值得用户判断的强 B 才能输出，不要为了覆盖类型而凑数。"
        case .balanced:
            return "输出倾向平衡：先输出 A 级，再补充确有创作潜力的 B 级；普通句子、普通反馈和弱相关内容仍然不要输出。"
        case .moreCandidates:
            return "输出倾向放宽：可以增加 B 级候选，但每条 B 都必须能说清潜力点；低价值内容不能用 B 级收纳。"
        }
    }
}

enum AssetSaveThreshold: String, Codable, CaseIterable, Sendable {
    case aOnly
    case aAndB

    var title: String {
        switch self {
        case .aOnly:
            return L("仅 A 级", "A only")
        case .aAndB:
            return L("A/B 都保留", "A/B")
        }
    }

    var promptInstruction: String {
        switch self {
        case .aOnly:
            return "只输出 grade=A 的候选；判为 B、不确定或低价值的内容不要进入 assets。"
        case .aAndB:
            return "输出 grade=A 和 grade=B；B 级必须满足对应类型的基础标准，不能把低价值内容标成 B。"
        }
    }
}

enum AssetPriorityDirection: String, Codable, CaseIterable, Sendable {
    case questionViewpoint
    case viewpointCase
    case expressionFirst

    var title: String {
        switch self {
        case .questionViewpoint:
            return L("问题/观点优先", "Question / viewpoint")
        case .viewpointCase:
            return L("观点/案例优先", "Viewpoint / case")
        case .expressionFirst:
            return L("表达优先", "Expression")
        }
    }

    var promptInstruction: String {
        switch self {
        case .questionViewpoint:
            return "优先提炼好问题和好观点，其次再提炼表达框架、案例素材、金句短句。"
        case .viewpointCase:
            return "优先提炼好观点和案例素材，其次再提炼好问题、表达框架、金句短句。"
        case .expressionFirst:
            return "优先提炼表达框架和金句短句，其次再提炼好问题、好观点、案例素材。"
        }
    }
}

enum AssetLowValueFilter: String, Codable, CaseIterable, Sendable {
    case light
    case standard
    case strong

    var title: String {
        switch self {
        case .light:
            return L("轻过滤", "Light")
        case .standard:
            return L("标准过滤", "Standard")
        case .strong:
            return L("强过滤", "Strong")
        }
    }

    var promptInstruction: String {
        switch self {
        case .light:
            return "只过滤明显寒暄、乱码、重复和无意义短句；其余内容仍需按 A/B 标准判断。"
        case .standard:
            return "过滤寒暄、重复表达、普通事实记录、没有创作价值的流水账；不确定但有潜力的内容可评为 B。"
        case .strong:
            return "严格过滤低信息量、普通记录、套话、情绪宣泄、只有上下文才成立的片段；宁可少，不要把普通内容放进 B。"
        }
    }
}

struct AssetTypeRuleConfig: Codable, Equatable, Sendable {
    var definition: String
    var saveRule: String
    var ignoreRule: String
    var example: String
}

struct AssetExtractionRuleConfig: Codable, Equatable, Sendable {
    var customPrompt: String
    var saveRule: String
    var ignoreRule: String
    var typeRules: [String: AssetTypeRuleConfig]
    var candidateQuantity: AssetCandidateQuantity
    var saveThreshold: AssetSaveThreshold
    var priorityDirection: AssetPriorityDirection
    var lowValueFilter: AssetLowValueFilter
    var audienceFocus: String

    static let defaultCustomPrompt = """
    只从原始输入中摘取能直接用于内容创作的语料资产，不做普通聊天记录存档，也不让模型代写、代答、代总结。优先识别好问题、好观点、表达框架、案例素材和金句短句；候选正文必须保留原文表达。
    """

    static let defaultSaveRule = """
    能独立复用，有明确观点、痛点、场景或表达价值；候选正文必须来自原始输入，离开原始上下文后仍然能看懂，并且适合进入问题库、观点库、框架库、案例库或金句库。宁可少，不要把普通句子、临时反馈和情绪吐槽当资产。
    """

    static let defaultIgnoreRule = """
    寒暄、重复表达、情绪碎片、普通事实流水账、临时产品反馈、操作指令、测试吐槽、无上下文无法理解的半句话、低信息量指令、明显噪声、模型总结出来但原文没有说过的内容都不要入库。
    """

    static let defaultTypeRules: [String: AssetTypeRuleConfig] = Dictionary(
        uniqueKeysWithValues: LanguageAssetType.creatorCases.map { type in
            (type.rawValue, defaultRule(for: type))
        }
    )

    static let `default` = AssetExtractionRuleConfig(
        customPrompt: defaultCustomPrompt,
        saveRule: defaultSaveRule,
        ignoreRule: defaultIgnoreRule,
        typeRules: defaultTypeRules,
        candidateQuantity: .balanced,
        saveThreshold: .aAndB,
        priorityDirection: .viewpointCase,
        lowValueFilter: .standard,
        audienceFocus: "内容创作者"
    )

    static func quoteOnly(prompt: String) -> AssetExtractionRuleConfig {
        AssetExtractionRuleConfig(
            customPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            saveRule: "只保留用户原文中已经说出的高密度短句；A 级必须独立完整、有明确讨论对象、有判断密度、有表达压缩感，并且能直接作为标题、结尾、转场、海报文案或口播高光句复用；对象明确的价值排序句可以判 A；B 级必须已经有清晰判断、反差或方法论，并且值得用户二次编辑；内部产品、课程、交付和功能决策不能因为有点方法论就进入 B；案例叙述、场景解释、举例段落不能因为生动就进入 B；有用信息不等于金句。",
            ignoreRule: "口水话、普通陈述、短但平的句子、长句解释、临时吐槽、操作反馈、测试内容、上下文不完整的半句话、对象不清的判断句、带“他们/也是一样/这句话/这件事/这个增强回路/这种方式/换一个/它就没有意义/他就没有意义”等承接表达但没有交代对象的句子、案例叙述、生活案例、故事片段、场景解释、背景铺垫、数据钩子、转场句、提问引子、针对某个具体稿件、案例、模型、方案、增强回路的局部批评、产品决策、课程定位、商业模式定价、交付设计、功能设计、页面交互、内部内容诊断、内部产品配置、项目执行建议、团队协作安排、只服务当前项目的对标拆解、模型改写或总结出来的漂亮句子都不要输出；普通句子不是 B。",
            typeRules: [LanguageAssetType.quote.rawValue: defaultRule(for: .quote)],
            candidateQuantity: .balanced,
            saveThreshold: .aAndB,
            priorityDirection: .expressionFirst,
            lowValueFilter: .standard,
            audienceFocus: ""
        )
    }

    init(
        customPrompt: String,
        saveRule: String,
        ignoreRule: String,
        typeRules: [String: AssetTypeRuleConfig],
        candidateQuantity: AssetCandidateQuantity,
        saveThreshold: AssetSaveThreshold,
        priorityDirection: AssetPriorityDirection,
        lowValueFilter: AssetLowValueFilter,
        audienceFocus: String
    ) {
        self.customPrompt = customPrompt
        self.saveRule = saveRule
        self.ignoreRule = ignoreRule
        self.typeRules = Self.mergingDefaults(into: typeRules)
        self.candidateQuantity = candidateQuantity
        self.saveThreshold = saveThreshold
        self.priorityDirection = priorityDirection
        self.lowValueFilter = lowValueFilter
        self.audienceFocus = audienceFocus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customPrompt = try container.decodeIfPresent(String.self, forKey: .customPrompt) ?? Self.defaultCustomPrompt
        saveRule = try container.decodeIfPresent(String.self, forKey: .saveRule) ?? Self.defaultSaveRule
        ignoreRule = try container.decodeIfPresent(String.self, forKey: .ignoreRule) ?? Self.defaultIgnoreRule
        typeRules = Self.mergingDefaults(
            into: try container.decodeIfPresent([String: AssetTypeRuleConfig].self, forKey: .typeRules) ?? [:]
        )
        candidateQuantity = try container.decodeIfPresent(AssetCandidateQuantity.self, forKey: .candidateQuantity) ?? .highValueOnly
        saveThreshold = try container.decodeIfPresent(AssetSaveThreshold.self, forKey: .saveThreshold) ?? .aAndB
        priorityDirection = try container.decodeIfPresent(AssetPriorityDirection.self, forKey: .priorityDirection) ?? .viewpointCase
        lowValueFilter = try container.decodeIfPresent(AssetLowValueFilter.self, forKey: .lowValueFilter) ?? .strong
        audienceFocus = try container.decodeIfPresent(String.self, forKey: .audienceFocus) ?? "内容创作者"
    }

    func typeRule(for type: LanguageAssetType) -> AssetTypeRuleConfig {
        typeRules[type.rawValue] ?? Self.defaultRule(for: type)
    }

    var promptBlock: String {
        let trimmedCustomPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSaveRule = saveRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIgnoreRule = ignoreRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAudienceFocus = audienceFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeRuleBlocks = LanguageAssetType.creatorCases.map { type -> String in
            let rule = typeRule(for: type)
            return """
            - \(Self.promptName(for: type))（type=\(type.rawValue)）
              定义：\(rule.definition.trimmingCharacters(in: .whitespacesAndNewlines))
              入库标准：\(rule.saveRule.trimmingCharacters(in: .whitespacesAndNewlines))
              忽略标准：\(rule.ignoreRule.trimmingCharacters(in: .whitespacesAndNewlines))
              参考示例：\(rule.example.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }.joined(separator: "\n")

        return """

        用户自定义提炼规则：
        等级判定规则：
        - A：可以直接进入资产库。content 本身来自原文，离开上下文仍能独立理解，并且可直接用于选题、观点、案例、框架或金句。
        - B：暂不确定但值得用户判断。content 来自原文，有明确创作潜力，但可能需要用户补充判断、改标题或决定是否归类。
        - 不输出：普通聊天、测试反馈、操作指令、情绪碎片、流水账、需要你总结/改写后才像资产的内容。

        判定流程：
        1. 先确认 content 是否能作为原文摘录存在；不能就不要输出。
        2. 再判断它最匹配哪一种资产类型；不要为了类型均衡强行归类。
        3. 再按 A/B/不输出评级；不确定但有创作潜力才是 B，普通内容不是 B。
        4. 最后按当前保留等级决定是否进入 assets。

        - 候选数量策略：\(candidateQuantity.title)。\(candidateQuantity.promptInstruction)
        - 类型优先方向：\(priorityDirection.title)。\(priorityDirection.promptInstruction)
        - 保留等级：\(saveThreshold.title)。\(saveThreshold.promptInstruction)
        - 过滤强度：\(lowValueFilter.title)。\(lowValueFilter.promptInstruction)
        - 重点人群：\(trimmedAudienceFocus.isEmpty ? "内容创作者" : trimmedAudienceFocus)
        \(trimmedCustomPrompt.isEmpty ? "" : "- 用户补充 Prompt：\(trimmedCustomPrompt)")
        \(trimmedSaveRule.isEmpty ? "" : "- 用户定义的好资产标准：\(trimmedSaveRule)")
        \(trimmedIgnoreRule.isEmpty ? "" : "- 用户定义的忽略标准：\(trimmedIgnoreRule)")

        各资产类型的提炼规则：
        \(typeRuleBlocks)
        """
    }

    var compactPromptBlock: String {
        let trimmedCustomPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSaveRule = saveRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIgnoreRule = ignoreRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAudienceFocus = audienceFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeRulesSummary = LanguageAssetType.creatorCases.map { type -> String in
            let rule = typeRule(for: type)
            return "- \(Self.promptName(for: type))(\(type.rawValue))：\(Self.compact(rule.definition)); 入库：\(Self.compact(rule.saveRule)); 忽略：\(Self.compact(rule.ignoreRule))"
        }.joined(separator: "\n")

        return """
        用户规则：
        等级：A=可直接入库、离开上下文能独立复用；B=有明确创作潜力但需用户判断；不输出=普通聊天/操作/测试/流水账/需改写后才像资产。
        流程：先验原文摘录，再判类型，再判 A/B/不输出，最后按保留等级输出。
        - 候选数量：\(candidateQuantity.title)，\(candidateQuantity.promptInstruction)
        - 类型优先：\(priorityDirection.title)，\(priorityDirection.promptInstruction)
        - 保留等级：\(saveThreshold.title)，\(saveThreshold.promptInstruction)
        - 过滤强度：\(lowValueFilter.title)，\(lowValueFilter.promptInstruction)
        - 重点人群：\(trimmedAudienceFocus.isEmpty ? "内容创作者" : Self.compact(trimmedAudienceFocus, limit: 80))
        \(trimmedCustomPrompt.isEmpty ? "" : "- 补充：\(Self.compact(trimmedCustomPrompt))")
        \(trimmedSaveRule.isEmpty ? "" : "- 好资产标准：\(Self.compact(trimmedSaveRule))")
        \(trimmedIgnoreRule.isEmpty ? "" : "- 忽略标准：\(Self.compact(trimmedIgnoreRule))")
        类型规则：
        \(typeRulesSummary)
        """
    }

    private static func mergingDefaults(
        into rules: [String: AssetTypeRuleConfig]
    ) -> [String: AssetTypeRuleConfig] {
        var merged = defaultTypeRules
        for (key, value) in rules {
            merged[key] = value
        }
        return merged
    }

    private static func promptName(for type: LanguageAssetType) -> String {
        switch type {
        case .question:
            return "好问题"
        case .viewpoint:
            return "好观点"
        case .framework:
            return "表达框架"
        case .caseMaterial:
            return "案例素材"
        case .quote:
            return "金句短句"
        case .term:
            return "高频术语"
        case .snippet:
            return "可复用片段"
        }
    }

    private static func compact(_ value: String, limit: Int = 120) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private static func defaultRule(for type: LanguageAssetType) -> AssetTypeRuleConfig {
        switch type {
        case .question:
            return AssetTypeRuleConfig(
                definition: "能作为内容选题或开头钩子的好问题，通常带有痛点、反差、悬念、讨论度或用户真实困惑。",
                saveRule: "问题本身能独立成立，能引出一篇内容；content 必须是用户原文里真实提出的问题或包含问题的原文片段，不允许写答案、建议或任何答题类内容。",
                ignoreRule: "普通求助、信息确认、没有讨论空间的问题、离开上下文无法理解的问题、模型代用户扩写出来的问题不要提炼。",
                example: "为什么收藏了很多爆款模板，还是写不出自己的爆款？"
            )
        case .viewpoint:
            return AssetTypeRuleConfig(
                definition: "有明确判断、立场、洞察或反常识表达的观点，能帮助用户形成认知或价值判断。",
                saveRule: "必须是用户原文里真实说出的陈述句或观点段落，有清晰主张、判断力度或认知增量；summary 可以概括，但 content 必须保留原文。",
                ignoreRule: "单纯情绪、普通事实、模糊态度、临时反馈、依赖上下文的半句话、没有判断力度的描述、模型把原文总结后生成的新观点都不要提炼成观点。",
                example: "收藏模板只是在保存别人的结果，真正能复用的是自己的判断路径。"
            )
        case .framework:
            return AssetTypeRuleConfig(
                definition: "可以复用的表达结构、内容组织方式、话术逻辑、开篇方式、结尾方式或段落排布。",
                saveRule: "必须是用户原文里已经说出的结构、步骤、流程、判断逻辑或话术组织方式；可以整理标题，但不能把零散内容代归纳成框架。",
                ignoreRule: "只有单句观点、没有结构关系、不能迁移到其他内容里的表达、模型事后总结出来的“三步法/公式”不要提炼成框架。",
                example: "先圈定人群，再指出痛点，最后给出反常识判断。"
            )
        case .caseMaterial:
            return AssetTypeRuleConfig(
                definition: "能支撑观点的故事、真实场景、生活实例、身边见闻、类比、客户案例或可讲述素材。",
                saveRule: "必须是用户原文里真实出现的案例、场景、类比、经历或事件，有人物、冲突、变化或可验证细节；不能把观点包装成案例。",
                ignoreRule: "纯流水账、只有情绪没有事件、缺少细节、无法支撑观点的记录、模型补出来的人物情节不要提炼。",
                example: "一个人收藏了很多爆款模板，却依然写不出内容，因为他只复制结果，没有训练判断。"
            )
        case .quote:
            return AssetTypeRuleConfig(
                definition: "能被单独摘出来复用的高密度短句，可作为标题、结尾、转场、海报文案或口播高光句。",
                saveRule: "必须是用户原文里已经说出的短句，离开上下文仍能成立，且句子本身包含明确讨论对象或核心概念，并且至少具备清晰判断、反差结构、因果洞察、价值排序、边界定义或方法论表达之一；还必须具备对外传播价值，不只是对当前项目有用；不允许根据原文重写、拔高或创作金句。",
                ignoreRule: "口水话、普通陈述、短但平的句子、长句解释、案例叙述、生活案例、故事片段、场景解释、背景铺垫、数据钩子、转场句、提问引子、临时吐槽、上下文不完整、对象不清、依赖“它/他/这个/那个/这句话/这个增强回路/咱们这个”等指代才能理解、内部工作方法、对标拆解、局部方案批评、产品功能决策、项目执行建议、只有情绪没有认知增量、没有复用场景的句子、模型改写出来但用户没说过的句子不要提炼成金句。",
                example: "真正能复用的不是模板，而是你的判断路径。"
            )
        case .term, .snippet:
            return AssetTypeRuleConfig(definition: "", saveRule: "", ignoreRule: "", example: "")
        }
    }
}

enum AssetExtractionRuleConfigStore {
    private static let key = "tf_assetExtractionRuleConfig"

    static func load() -> AssetExtractionRuleConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(AssetExtractionRuleConfig.self, from: data)
        else {
            return .default
        }
        return config.migratingLegacyGenerativeRules()
    }

    static func save(_ config: AssetExtractionRuleConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private extension AssetExtractionRuleConfig {
    func migratingLegacyGenerativeRules() -> AssetExtractionRuleConfig {
        var updated = self
        for type in LanguageAssetType.creatorCases {
            guard let rule = updated.typeRules[type.rawValue],
                  Self.isLegacyGenerativeRule(rule, for: type)
            else { continue }
            updated.typeRules[type.rawValue] = Self.defaultRule(for: type)
        }
        return updated
    }

    static func isLegacyGenerativeRule(_ rule: AssetTypeRuleConfig, for type: LanguageAssetType) -> Bool {
        switch type {
        case .question:
            return rule.saveRule.contains("回答方向")
        case .viewpoint:
            return rule.saveRule == "必须是陈述句，有清晰主张和可复用表达；最好能支撑选题、评论、口播或文章核心段落。"
        case .framework:
            return rule.saveRule == "能指导用户怎么写、怎么讲、怎么组织内容；最好能抽象成步骤、公式或结构。"
        case .caseMaterial:
            return rule.saveRule == "场景具体，有人物、冲突、变化或可验证细节；能作为文章或口播里的论据。"
        case .quote:
            return rule.saveRule == "必须凝练、有力度、能独立传播；可以扎心、反常识、总结性强或有节奏感。"
        case .term, .snippet:
            return false
        }
    }
}
