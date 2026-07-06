import Foundation

enum ExtractionOutputKind: String, Codable, CaseIterable, Sendable {
    case assetCandidates = "asset_candidates"
    case todoList = "todo_list"
    case dailyReport = "daily_report"
    case summary
    case custom
}

enum ExtractionProcessingStrategy: String, Codable, CaseIterable, Sendable {
    case whole
    case mapReduce = "map_reduce"
    case parallel
}

enum ExtractionSourcePolicy: String, Codable, CaseIterable, Sendable {
    case strictQuote = "strict_quote"
    case citedSummary = "cited_summary"
    case evidenceRequired = "evidence_required"
}

enum ExtractionDestination: String, Codable, CaseIterable, Sendable {
    case assetCandidatePool = "asset_candidate_pool"
    case resultArchive = "result_archive"
    case todoList = "todo_list"
    case document
}

enum ExtractionRecipeStatus: String, Codable, Sendable {
    case active
    case archived
}

enum ExtractionRunStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
}

enum ExtractionResultStatus: String, Codable, Sendable {
    /// 待确认：两段式管线产物的统一落点，等用户拍板（2026-07 重构）
    case pending
    /// 已入库：用户确认储存，进资产库
    case saved
    /// 已抛弃：用户判定不要（保留行以便审计/防重复提炼）
    case discarded
    /// 严审砍掉：机器判不达标（与用户抛弃分开存，UI 可翻砍单、可捞回——防错杀）
    case rejected
    // 旧三态，仅供老界面过渡编译，批四清退
    case active
    case archived
    case deleted
}

struct ExtractionRecipe: Identifiable, Hashable, Codable, Sendable {
    static let quoteAssetsID = "builtin.quote_assets"
    static let contentCreatorAssetsID = "builtin.content_creator_assets"
    static let todayTodosID = "builtin.today_todos"
    static let dailyReportID = "builtin.daily_report"

    let id: String
    let createdAt: Date
    let updatedAt: Date
    let name: String
    let recipeDescription: String
    let goalPrompt: String
    let outputKind: ExtractionOutputKind
    let processingStrategy: ExtractionProcessingStrategy
    let sourcePolicy: ExtractionSourcePolicy
    let outputSchema: String
    let qualityRules: String
    /// 入库标准：严审段判「留」的依据（2026-07 重构：一切皆配方，标准从全局规则页收编到配方自身）
    let saveRule: String
    /// 忽略标准：严审段判「砍」的依据
    let ignoreRule: String
    let destination: ExtractionDestination
    let isBuiltIn: Bool
    let status: ExtractionRecipeStatus

    var isAssetCandidateRecipe: Bool {
        outputKind == .assetCandidates
    }

    /// 用户视角的「一段 Prompt」（2026-07 重设计：配方=名称+形态+一段 prompt）。
    /// 老配方的目标/入库标准/忽略标准/质量规则四字段自动拼成完整指令；
    /// 用户在编辑器里看到并编辑的就是这个全文，保存后全文回存 goalPrompt、其余字段清空——
    /// 宽提按它找、严审按它判，用户看到的即生效的
    var unifiedPrompt: String {
        let sections: [(String, String)] = [
            ("", goalPrompt),
            (L("该保留：", "Keep: "), saveRule),
            (L("不要输出：", "Do not output: "), ignoreRule),
            (L("质量纪律：", "Quality rules: "), qualityRules),
        ]
        return sections
            .compactMap { prefix, text -> String? in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : prefix + trimmed
            }
            .joined(separator: "\n\n")
    }

    static func builtInRecipes(now: Date = Date()) -> [ExtractionRecipe] {
        [
            quoteAssets(now: now),
            contentCreatorAssets(now: now),
            todayTodos(now: now),
            dailyReport(now: now),
        ]
    }

    static func builtInRecipe(id: String, now: Date = Date()) -> ExtractionRecipe? {
        switch id {
        case quoteAssetsID:
            return quoteAssets(now: now)
        case contentCreatorAssetsID:
            return contentCreatorAssets(now: now)
        case todayTodosID:
            return todayTodos(now: now)
        case dailyReportID:
            return dailyReport(now: now)
        default:
            return nil
        }
    }

    static func quoteAssets(now: Date = Date()) -> ExtractionRecipe {
        ExtractionRecipe(
            id: quoteAssetsID,
            createdAt: now,
            updatedAt: now,
            name: "金句",
            recipeDescription: "从语音输入中摘取用户原文里已经说出的高密度短句。",
            goalPrompt: "只提炼能作为金句沉淀的原文短句，最终进入待确认，由用户决定是否入库。",
            outputKind: .assetCandidates,
            processingStrategy: .mapReduce,
            sourcePolicy: .strictQuote,
            outputSchema: "assets: [{type=quote, grade, title, content, summary, reason, scenes, audiences, rule_hit, source_record_ids}]",
            qualityRules: "content 必须是原文连续片段；禁止改写、润色、拔高或创作用户没说过的金句；禁止提炼依赖上下文指代的半句话。",
            saveRule: "只保留用户原文中已经说出的高密度短句；A 级必须独立完整、有明确讨论对象、有判断密度、有表达压缩感，并且能直接作为标题、结尾、转场、海报文案或口播高光句复用；对象明确的价值排序句可以判 A；B 级必须已经有清晰判断、反差或方法论，并且值得用户二次编辑；内部产品、课程、交付和功能决策不能因为有点方法论就进入 B；案例叙述、场景解释、举例段落不能因为生动就进入 B；有用信息不等于金句。",
            ignoreRule: "口水话、普通陈述、短但平的句子、长句解释、临时吐槽、操作反馈、测试内容、上下文不完整的半句话、对象不清的判断句、带“他们/也是一样/这句话/这件事/这个增强回路/这种方式/换一个/它就没有意义/他就没有意义”等承接表达但没有交代对象的句子、案例叙述、生活案例、故事片段、场景解释、背景铺垫、数据钩子、转场句、提问引子、针对某个具体稿件、案例、模型、方案、增强回路的局部批评、产品决策、课程定位、商业模式定价、交付设计、功能设计、页面交互、内部内容诊断、内部产品配置、项目执行建议、团队协作安排、只服务当前项目的对标拆解、模型改写或总结出来的漂亮句子都不要输出；普通句子不是 B。",
            destination: .assetCandidatePool,
            isBuiltIn: true,
            status: .active
        )
    }

    static func contentCreatorAssets(now: Date = Date()) -> ExtractionRecipe {
        ExtractionRecipe(
            id: contentCreatorAssetsID,
            createdAt: now,
            updatedAt: now,
            name: "内容创作素材",
            recipeDescription: "从语音输入中提炼可复用的好问题、好观点、表达框架、案例素材和金句短句。",
            goalPrompt: "只提炼能直接服务内容创作的素材，最终进入待审候选，由用户决定是否入库。",
            outputKind: .assetCandidates,
            processingStrategy: .mapReduce,
            sourcePolicy: .strictQuote,
            outputSchema: "asset_candidates: [{type, grade, title, content, summary, reason, scenes, audiences, rule_hit, source_record_ids}]",
            qualityRules: "候选正文必须来自原文；禁止回答、总结、改写或创作用户没说过的内容。",
            saveRule: "能独立复用，有明确观点、痛点、场景或表达价值；候选正文必须来自原始输入，离开原始上下文后仍然能看懂，并且适合进入问题库、观点库、框架库、案例库或金句库。宁可少，不要把普通句子、临时反馈和情绪吐槽当资产。",
            ignoreRule: "寒暄、重复表达、情绪碎片、普通事实流水账、临时产品反馈、操作指令、测试吐槽、无上下文无法理解的半句话、低信息量指令、明显噪声、模型总结出来但原文没有说过的内容都不要入库。",
            destination: .assetCandidatePool,
            isBuiltIn: true,
            status: .active
        )
    }

    static func todayTodos(now: Date = Date()) -> ExtractionRecipe {
        ExtractionRecipe(
            id: todayTodosID,
            createdAt: now,
            updatedAt: now,
            name: "待办",
            recipeDescription: "从选定范围的语音输入中整理待办、跟进事项和承诺。",
            goalPrompt: "把范围内语料作为整体阅读，只提炼用户明确提到要做、要跟进、要确认的事项。",
            outputKind: .todoList,
            processingStrategy: .whole,
            sourcePolicy: .evidenceRequired,
            outputSchema: "todos: [{title, detail, priority, due_hint, evidence, source_record_ids}]",
            qualityRules: "允许整理措辞，但每条待办必须有原文依据；不要把普通想法误判为待办。",
            saveRule: "用户明确说到要做、要跟进、要确认、要交付的事项；每条有原文依据，行动指向清晰，能写成一句可执行的待办。",
            ignoreRule: "普通想法、感慨、假设性讨论、已完成事项的陈述、没有行动语义的句子不要输出；不确定是否要做的犹豫内容不要硬判成待办；用户对 AI 工具说的当场执行型操作指令（改文案、调设计、改代码这类说完立刻被执行的）不算待办，除非用户明确说之后要做。",
            destination: .todoList,
            isBuiltIn: true,
            status: .active
        )
    }

    static func dailyReport(now: Date = Date()) -> ExtractionRecipe {
        ExtractionRecipe(
            id: dailyReportID,
            createdAt: now,
            updatedAt: now,
            name: "工作日报",
            recipeDescription: "把选定范围内的语音输入整理成一份可读的工作日报或阶段总结。",
            goalPrompt: "把所有语料作为一个整体，提炼今天做了什么、推进了什么、遇到什么问题、下一步是什么。",
            outputKind: .dailyReport,
            processingStrategy: .whole,
            sourcePolicy: .citedSummary,
            outputSchema: "report: {title, sections: [{heading, body, source_record_ids}], next_steps: []}",
            qualityRules: "允许总结，但每个关键结论必须绑定来源记录；不要补充原文没有的信息。",
            saveRule: "有原文依据的实际进展、遇到的问题、明确的下一步；关键结论必须能对应到来源记录。",
            ignoreRule: "不要补充原文没有的信息；与工作无关的闲聊、情绪表达不进日报；不要把一句提及扩写成一段成果。",
            destination: .document,
            isBuiltIn: true,
            status: .active
        )
    }

    static func custom(
        id: String = "custom.\(UUID().uuidString)",
        now: Date = Date(),
        name: String,
        recipeDescription: String,
        goalPrompt: String,
        outputKind: ExtractionOutputKind = .custom,
        processingStrategy: ExtractionProcessingStrategy = .whole,
        sourcePolicy: ExtractionSourcePolicy = .evidenceRequired,
        outputSchema: String = #"results: [{title, content, summary, payload_json, source_record_ids}]"#,
        qualityRules: String,
        saveRule: String = "",
        ignoreRule: String = "",
        destination: ExtractionDestination = .resultArchive,
        status: ExtractionRecipeStatus = .active
    ) -> ExtractionRecipe {
        ExtractionRecipe(
            id: id,
            createdAt: now,
            updatedAt: now,
            name: name,
            recipeDescription: recipeDescription,
            goalPrompt: goalPrompt,
            outputKind: outputKind,
            processingStrategy: processingStrategy,
            sourcePolicy: sourcePolicy,
            outputSchema: outputSchema,
            qualityRules: qualityRules,
            saveRule: saveRule,
            ignoreRule: ignoreRule,
            destination: destination,
            isBuiltIn: false,
            status: status
        )
    }

    func asUserDefinition(now: Date = Date()) -> ExtractionRecipe {
        ExtractionRecipe.custom(
            now: now,
            name: name,
            recipeDescription: recipeDescription,
            goalPrompt: goalPrompt,
            outputKind: outputKind == .assetCandidates ? .custom : outputKind,
            processingStrategy: processingStrategy,
            sourcePolicy: sourcePolicy,
            outputSchema: outputSchema,
            qualityRules: qualityRules,
            saveRule: saveRule,
            ignoreRule: ignoreRule,
            destination: destination == .assetCandidatePool ? .resultArchive : destination,
            status: .active
        )
    }

    func updating(
        now: Date = Date(),
        name: String,
        recipeDescription: String,
        goalPrompt: String,
        outputKind: ExtractionOutputKind,
        processingStrategy: ExtractionProcessingStrategy,
        sourcePolicy: ExtractionSourcePolicy,
        outputSchema: String,
        qualityRules: String,
        saveRule: String,
        ignoreRule: String,
        destination: ExtractionDestination,
        status: ExtractionRecipeStatus
    ) -> ExtractionRecipe {
        ExtractionRecipe(
            id: id,
            createdAt: createdAt,
            updatedAt: now,
            name: name,
            recipeDescription: recipeDescription,
            goalPrompt: goalPrompt,
            outputKind: outputKind,
            processingStrategy: processingStrategy,
            sourcePolicy: sourcePolicy,
            outputSchema: outputSchema,
            qualityRules: qualityRules,
            saveRule: saveRule,
            ignoreRule: ignoreRule,
            destination: destination,
            isBuiltIn: isBuiltIn,
            status: status
        )
    }
}

struct AssetDefinitionTemplateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let templates: [ExtractionRecipe]
}

extension AssetDefinitionTemplateGroup {
    static func defaults(now: Date = Date()) -> [AssetDefinitionTemplateGroup] {
        [
            AssetDefinitionTemplateGroup(
                id: "creator",
                name: "创作灵感类",
                description: "适合内容创作者沉淀选题、问题、观点和表达素材。",
                templates: [
                    .template(
                        id: "template.creator.topic",
                        now: now,
                        name: "内容选题",
                        recipeDescription: "从日常输入里捕捉可以发展成内容的主题和切入点。",
                        goalPrompt: "把选定语料作为整体阅读，提炼用户明确提到、值得继续展开成内容的选题、角度或切入点。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "topics: [{title, angle, why_it_matters, evidence, source_record_ids}]",
                        qualityRules: "只保留有明确原文依据、能发展成内容的选题；不要替用户虚构热点或结论。",
                        saveRule: "有明确原文依据、能发展成一篇内容的选题、角度或切入点。",
                        ignoreRule: "一闪而过、没有展开价值的念头不要输出；不要替用户虚构热点或结论。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.creator.question",
                        now: now,
                        name: "好问题",
                        recipeDescription: "提炼真正能引发讨论、研究或内容展开的问题。",
                        goalPrompt: "只提炼用户原文中提出或明显围绕的问题，优先保留原始问法。",
                        outputKind: .custom,
                        processingStrategy: .mapReduce,
                        sourcePolicy: .strictQuote,
                        outputSchema: "questions: [{question, context, value_reason, source_record_ids}]",
                        qualityRules: "问题必须来自原文或原文清晰语义；禁止回答问题；禁止把普通陈述改写成看似高级的问题。",
                        saveRule: "用户原文提出或明显围绕的问题，优先保留原始问法，真正能引发讨论、研究或内容展开。",
                        ignoreRule: "禁止回答问题；禁止把普通陈述改写成问题；修辞性反问、没有展开价值的疑问不要输出。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.creator.viewpoint",
                        now: now,
                        name: "好观点",
                        recipeDescription: "沉淀用户已经表达过、可复用到内容中的判断和立场。",
                        goalPrompt: "提炼用户明确说出的观点、判断、立场或方法选择，优先展示原始输入，再给一句必要说明。",
                        outputKind: .custom,
                        processingStrategy: .mapReduce,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "viewpoints: [{original_text, title, context, source_record_ids}]",
                        qualityRules: "不得替用户总结出没说过的新观点；如果需要压缩，必须保留原文核心措辞。",
                        saveRule: "用户明确说出的观点、判断、立场或方法选择，保留原文核心措辞，离开上下文仍能独立理解。",
                        ignoreRule: "人云亦云的常识性表态、情绪化表达、对象不清的判断不要输出；不得总结出用户没说过的新观点。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.creator.expression",
                        now: now,
                        name: "表达素材",
                        recipeDescription: "保留有辨识度、可直接复用的表达、比喻、标题感句子。",
                        goalPrompt: "从语料里摘取用户已经说出的、有表达价值的原文片段。",
                        outputKind: .custom,
                        processingStrategy: .mapReduce,
                        sourcePolicy: .strictQuote,
                        outputSchema: "expressions: [{quote, usage_hint, source_record_ids}]",
                        qualityRules: "必须是原文连续片段；没有真正表达价值就不要输出；禁止润色成用户没说过的金句。",
                        saveRule: "原文连续片段，有辨识度、可直接复用的表达、比喻或标题感句子。",
                        ignoreRule: "普通通顺句子不算表达素材；禁止润色成用户没说过的句子。",
                        destination: .resultArchive
                    ),
                ]
            ),
            AssetDefinitionTemplateGroup(
                id: "work",
                name: "工作效率类",
                description: "适合把语音记录整理成行动、日报、会议结论和风险。",
                templates: [
                    .template(
                        id: "template.work.todo",
                        now: now,
                        name: "待办",
                        recipeDescription: "整理待办、承诺、跟进和需要确认的事项。",
                        goalPrompt: "只提炼用户明确说到要做、要跟进、要确认、要交付的事情。",
                        outputKind: .todoList,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "todos: [{title, detail, priority, due_hint, evidence, source_record_ids}]",
                        qualityRules: "不要把普通想法误判为待办；每条待办必须有原文依据。",
                        saveRule: "用户明确说到要做、要跟进、要确认、要交付的事项；每条有原文依据，行动指向清晰。",
                        ignoreRule: "普通想法、感慨、假设性讨论、已完成事项的陈述不要输出；犹豫内容不要硬判成待办。",
                        destination: .todoList
                    ),
                    .template(
                        id: "template.work.report",
                        now: now,
                        name: "工作日报",
                        recipeDescription: "把选定范围内的工作输入整理成日报或阶段总结。",
                        goalPrompt: "提炼做了什么、推进了什么、遇到什么问题、下一步是什么。",
                        outputKind: .dailyReport,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "report: {title, sections: [{heading, body, source_record_ids}], next_steps: []}",
                        qualityRules: "允许总结，但关键结论必须绑定来源记录；不要补充原文没有的信息。",
                        saveRule: "有原文依据的实际进展、遇到的问题、明确的下一步；关键结论必须能对应到来源记录。",
                        ignoreRule: "不要补充原文没有的信息；与工作无关的闲聊不进日报；不要把一句提及扩写成一段成果。",
                        destination: .document
                    ),
                    .template(
                        id: "template.work.meeting",
                        now: now,
                        name: "会议结论",
                        recipeDescription: "整理讨论中的结论、决定、分歧和后续动作。",
                        goalPrompt: "从语料中提炼已经达成的结论、未决问题、责任人线索和下一步动作。",
                        outputKind: .summary,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "meeting_notes: {conclusions: [], open_questions: [], next_actions: [], source_record_ids: []}",
                        qualityRules: "不要把个人猜测写成会议结论；无法确认责任人时写明未明确。",
                        saveRule: "已经达成的结论、明确的决定、未决问题和下一步动作，须有原文依据。",
                        ignoreRule: "个人猜测不要写成会议结论；无法确认的责任人写明未明确，不要编造。",
                        destination: .document
                    ),
                    .template(
                        id: "template.work.risk",
                        now: now,
                        name: "项目风险",
                        recipeDescription: "发现阻塞、风险、依赖和需要提前处理的问题。",
                        goalPrompt: "提炼用户提到的风险、阻塞、依赖、异常和可能影响交付的信号。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "risks: [{title, impact, evidence, possible_next_step, source_record_ids}]",
                        qualityRules: "只保留有明确依据的风险；不要为了凑数输出普通事项。",
                        saveRule: "有明确依据的风险、阻塞、依赖、异常和可能影响交付的信号。",
                        ignoreRule: "不要为了凑数把普通事项包装成风险；纯情绪化担忧没有事实依据不要输出。",
                        destination: .resultArchive
                    ),
                ]
            ),
            AssetDefinitionTemplateGroup(
                id: "personal",
                name: "个人记录类",
                description: "适合沉淀复盘、状态、决定和长期目标线索。",
                templates: [
                    .template(
                        id: "template.personal.review",
                        now: now,
                        name: "复盘",
                        recipeDescription: "整理选定范围内的重要进展、反思、收获和需要改进的地方。",
                        goalPrompt: "把语料作为整体阅读，提炼这段时间发生了什么、学到了什么、哪里需要调整。",
                        outputKind: .summary,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "review: {wins: [], lessons: [], adjustments: [], source_record_ids: []}",
                        qualityRules: "允许总结，但不要替用户做心理分析；必须能从原文找到依据。",
                        saveRule: "今天实际发生的进展、反思、收获和需要调整的地方，能从原文找到依据。",
                        ignoreRule: "不要替用户做心理分析；不要把流水账当复盘结论。",
                        destination: .document
                    ),
                    .template(
                        id: "template.personal.decision",
                        now: now,
                        name: "重要决定",
                        recipeDescription: "记录用户明确做出的选择、判断和取舍。",
                        goalPrompt: "提炼用户已经明确表达的决定、取舍、判断依据和后续影响。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "decisions: [{decision, reason, tradeoff, source_record_ids}]",
                        qualityRules: "只有明确决定才输出；犹豫、假设和闲聊不要写成决定。",
                        saveRule: "用户已经明确表达的决定、取舍和判断依据。",
                        ignoreRule: "犹豫、假设、闲聊和未定的讨论不要写成决定。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.personal.state",
                        now: now,
                        name: "状态记录",
                        recipeDescription: "沉淀用户主动提到的情绪、精力和状态变化。",
                        goalPrompt: "提炼用户自己明确描述的状态、情绪、压力、能量和触发原因。",
                        outputKind: .summary,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "states: [{state, trigger, evidence, source_record_ids}]",
                        qualityRules: "不做诊断，不推测心理原因；只记录用户明确说出的状态。",
                        saveRule: "用户自己明确描述的状态、情绪、精力变化和触发原因。",
                        ignoreRule: "不做诊断，不推测心理原因；用户没明说的状态不要记录。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.personal.goal",
                        now: now,
                        name: "长期目标线索",
                        recipeDescription: "发现反复出现的目标、方向和长期关注点。",
                        goalPrompt: "从语料中提炼用户反复提到或明确重视的长期目标、方向和机会线索。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "goal_signals: [{goal, signal, why_relevant, source_record_ids}]",
                        qualityRules: "不要把一次性的普通想法升级成长期目标；必须说明来源线索。",
                        saveRule: "反复出现或用户明确重视的长期目标、方向和机会线索，说明来源。",
                        ignoreRule: "一次性的普通想法不要升级成长期目标。",
                        destination: .resultArchive
                    ),
                ]
            ),
            AssetDefinitionTemplateGroup(
                id: "knowledge",
                name: "知识沉淀类",
                description: "适合沉淀概念、方法、笔记和可复用框架。",
                templates: [
                    .template(
                        id: "template.knowledge.method",
                        now: now,
                        name: "方法论",
                        recipeDescription: "提炼用户说出的步骤、原则、判断方法和操作路径。",
                        goalPrompt: "识别语料中可复用的方法、流程、判断原则和操作步骤。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "methods: [{name, steps, principle, source_record_ids}]",
                        qualityRules: "必须来自用户实际表达；不要把普通观点包装成方法论。",
                        saveRule: "用户实际说出的可复用方法、流程、判断原则和操作步骤。",
                        ignoreRule: "不要把普通观点包装成方法论；只有一句感想没有步骤或原则的不算。",
                        destination: .resultArchive
                    ),
                    .template(
                        id: "template.knowledge.concept",
                        now: now,
                        name: "概念解释",
                        recipeDescription: "整理用户对概念、术语、现象的解释和定义。",
                        goalPrompt: "提炼用户对某个概念、术语、现象的解释、定义和边界。",
                        outputKind: .summary,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "concepts: [{concept, explanation, boundary, source_record_ids}]",
                        qualityRules: "不要补充用户没说过的百科知识；只整理原文中已有解释。",
                        saveRule: "用户对概念、术语、现象的解释、定义和边界，原文中已有的。",
                        ignoreRule: "不要补充用户没说过的百科知识；只是提到名词但没解释的不算。",
                        destination: .document
                    ),
                    .template(
                        id: "template.knowledge.note",
                        now: now,
                        name: "学习笔记",
                        recipeDescription: "把学习、阅读、听课中的收获整理成笔记。",
                        goalPrompt: "提炼用户提到的新知识、启发、疑问和可复习要点。",
                        outputKind: .summary,
                        processingStrategy: .whole,
                        sourcePolicy: .citedSummary,
                        outputSchema: "notes: {key_points: [], questions: [], applications: [], source_record_ids: []}",
                        qualityRules: "只整理用户输入中的学习内容；不要额外扩写成教材。",
                        saveRule: "用户提到的新知识、启发、疑问和可复习要点。",
                        ignoreRule: "只整理原文中的学习内容，不要扩写成教材。",
                        destination: .document
                    ),
                    .template(
                        id: "template.knowledge.framework",
                        now: now,
                        name: "可复用框架",
                        recipeDescription: "发现可迁移到别的场景的结构、模型和分析框架。",
                        goalPrompt: "提炼语料中出现的结构化表达、分析框架、分类方式和决策模型。",
                        outputKind: .custom,
                        processingStrategy: .whole,
                        sourcePolicy: .evidenceRequired,
                        outputSchema: "frameworks: [{name, structure, use_case, source_record_ids}]",
                        qualityRules: "只有真的有结构时才输出；不要把零散句子硬整理成框架。",
                        saveRule: "原文中真实出现的结构化表达、分析框架、分类方式和决策模型。",
                        ignoreRule: "不要把零散句子硬整理成框架；没有可迁移性的一次性结构不算。",
                        destination: .resultArchive
                    ),
                ]
            ),
        ]
    }
}

private extension ExtractionRecipe {
    static func template(
        id: String,
        now: Date,
        name: String,
        recipeDescription: String,
        goalPrompt: String,
        outputKind: ExtractionOutputKind,
        processingStrategy: ExtractionProcessingStrategy,
        sourcePolicy: ExtractionSourcePolicy,
        outputSchema: String,
        qualityRules: String,
        saveRule: String,
        ignoreRule: String,
        destination: ExtractionDestination
    ) -> ExtractionRecipe {
        ExtractionRecipe(
            id: id,
            createdAt: now,
            updatedAt: now,
            name: name,
            recipeDescription: recipeDescription,
            goalPrompt: goalPrompt,
            outputKind: outputKind,
            processingStrategy: processingStrategy,
            sourcePolicy: sourcePolicy,
            outputSchema: outputSchema,
            qualityRules: qualityRules,
            saveRule: saveRule,
            ignoreRule: ignoreRule,
            destination: destination,
            isBuiltIn: true,
            status: .active
        )
    }
}

extension ExtractionRecipe {
    var promptBlock: String {
        """
        当前提炼方案：\(name)（\(recipeDescription)）

        用户对这个方案的完整要求：
        \(unifiedPrompt)

        来源约束：\(sourcePolicy.promptInstruction)
        """
    }

    var compactPromptBlock: String {
        "方案：\(name)。要求：\(unifiedPrompt)。来源：\(sourcePolicy.promptInstruction)"
    }
}

private extension ExtractionProcessingStrategy {
    var promptInstruction: String {
        switch self {
        case .whole:
            return "把选定范围内的所有记录作为一个整体阅读，再产出结果。"
        case .mapReduce:
            return "先在单条或小批记录里找候选，再合并、去重、排序。"
        case .parallel:
            return "可按独立目标并行处理，但每个结果仍必须绑定来源。"
        }
    }
}

private extension ExtractionSourcePolicy {
    var promptInstruction: String {
        switch self {
        case .strictQuote:
            return "核心正文必须来自原文连续片段，禁止改写、总结或创作不存在的表达。"
        case .citedSummary:
            return "允许总结，但关键结论必须引用或绑定来源记录，不得补充原文没有的信息。"
        case .evidenceRequired:
            return "每条结果必须有明确原文依据；没有依据就不要输出。"
        }
    }
}

struct ExtractionRun: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let recipeID: String
    let recipeName: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let rangeType: AssetExtractionRangeType
    let rangePayload: String?
    let sourceRecordCount: Int
    let status: ExtractionRunStatus
    let resultCount: Int
    let summary: String?
    let errorMessage: String?
}

struct ExtractionResult: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let runID: String
    let recipeID: String
    let createdAt: Date
    let updatedAt: Date
    let outputKind: ExtractionOutputKind
    let title: String
    let content: String
    let summary: String?
    let payloadJSON: String
    let sourceRecordIDs: [String]
    let sourceRecordCount: Int
    var status: ExtractionResultStatus
    /// 严审段评分（0-100），宽提直落的产物为 nil
    var score: Double?
    /// 严审段判决理由：为什么留（用户在待确认里可见，可审计）
    var reviewReason: String?
    /// 入库后用户收藏标记
    var isFavorite: Bool = false
}
