import XCTest
@testable import Muse

final class AssetExtractionRuleConfigTests: XCTestCase {

    func testPromptBlockIncludesUserRulesRetentionFilteringAndAudience() {
        let config = AssetExtractionRuleConfig(
            customPrompt: "优先保留反常识表达",
            saveRule: "能直接变成标题或口播",
            ignoreRule: "普通流水账不要入库",
            typeRules: AssetExtractionRuleConfig.defaultTypeRules,
            candidateQuantity: .moreCandidates,
            saveThreshold: .aOnly,
            priorityDirection: .questionViewpoint,
            lowValueFilter: .strong,
            audienceFocus: "个人IP"
        )

        let promptBlock = config.promptBlock

        XCTAssertTrue(promptBlock.contains("优先保留反常识表达"))
        XCTAssertTrue(promptBlock.contains("能直接变成标题或口播"))
        XCTAssertTrue(promptBlock.contains("普通流水账不要入库"))
        XCTAssertTrue(promptBlock.contains("个人IP"))
        XCTAssertTrue(promptBlock.contains(AssetSaveThreshold.aOnly.title))
        XCTAssertTrue(promptBlock.contains(AssetLowValueFilter.strong.title))
        XCTAssertTrue(promptBlock.contains(AssetCandidateQuantity.moreCandidates.title))
        XCTAssertTrue(promptBlock.contains(AssetPriorityDirection.questionViewpoint.title))
        XCTAssertTrue(promptBlock.contains(AssetCandidateQuantity.moreCandidates.promptInstruction))
        XCTAssertTrue(promptBlock.contains(AssetPriorityDirection.questionViewpoint.promptInstruction))
        XCTAssertTrue(promptBlock.contains("等级判定规则"))
        XCTAssertTrue(promptBlock.contains("判定流程"))
        XCTAssertTrue(promptBlock.contains("普通内容不是 B"))
        XCTAssertTrue(promptBlock.contains("用户原文"))
        XCTAssertFalse(promptBlock.contains("回答方向"))
    }

    func testCompactPromptBlockKeepsCoreRulesAndOmitsExamples() {
        let config = AssetExtractionRuleConfig(
            customPrompt: "优先保留反常识表达",
            saveRule: "能直接变成标题或口播",
            ignoreRule: "普通流水账不要入库",
            typeRules: AssetExtractionRuleConfig.defaultTypeRules,
            candidateQuantity: .balanced,
            saveThreshold: .aAndB,
            priorityDirection: .viewpointCase,
            lowValueFilter: .standard,
            audienceFocus: "内容创作者"
        )

        let compactBlock = config.compactPromptBlock

        XCTAssertTrue(compactBlock.contains("优先保留反常识表达"))
        XCTAssertTrue(compactBlock.contains("能直接变成标题或口播"))
        XCTAssertTrue(compactBlock.contains("普通流水账不要入库"))
        XCTAssertTrue(compactBlock.contains(AssetCandidateQuantity.balanced.title))
        XCTAssertTrue(compactBlock.contains(AssetPriorityDirection.viewpointCase.title))
        XCTAssertTrue(compactBlock.contains("A=可直接入库"))
        XCTAssertTrue(compactBlock.contains("先验原文摘录"))
        XCTAssertTrue(compactBlock.contains("好问题(question)"))
        XCTAssertTrue(compactBlock.contains("原文"))
        XCTAssertFalse(compactBlock.contains("回答方向"))
        XCTAssertFalse(compactBlock.contains("参考示例"))
    }

    func testPromptMessagesExposeActualSystemAndUserPayloads() {
        let record = HistoryRecord(
            id: "r1",
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 1,
            rawText: "原始文本",
            processingMode: "直出",
            processedText: nil,
            finalText: "真正能复用的不是模板，而是你的判断路径。",
            status: "completed",
            characterCount: 20
        )
        let configuration = AssetExtractionConfiguration
            .recent(limit: 10)
            .applying(ruleConfig: .default)

        let messages = RemoteAssetExtractionProvider.promptMessages(
            from: [record],
            configuration: configuration,
            provider: .deepseek
        )

        XCTAssertTrue(messages.system?.contains("创作者语料资产候选提炼器") == true)
        XCTAssertTrue(messages.system?.contains("当前提炼方案") == true)
        XCTAssertTrue(messages.system?.contains("内容创作素材") == true)
        // 2026-07 重设计：promptBlock 以配方统一 Prompt(完整要求)为中心，不再罗列工程字段
        XCTAssertTrue(messages.system?.contains("完整要求") == true)
        XCTAssertTrue(messages.system?.contains("用户自定义提炼规则") == true)
        XCTAssertFalse(messages.system?.contains("{text}") == true)
        XCTAssertTrue(messages.user.contains("[记录]"))
        XCTAssertTrue(messages.user.contains("id: r1"))
        XCTAssertTrue(messages.user.contains("真正能复用的不是模板"))
    }

    func testQuoteOnlyPromptKeepsStrictQuoteQualityBar() {
        let record = HistoryRecord(
            id: "quote-1",
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 1,
            rawText: "原始文本",
            processingMode: "直出",
            processedText: nil,
            finalText: "真正能复用的不是模板，而是你的判断路径。",
            status: "completed",
            characterCount: 20
        )
        let configuration = AssetExtractionConfiguration
            .recent(limit: 10)
            .applying(recipeID: ExtractionRecipe.quoteAssetsID)
            .applying(ruleConfig: .quoteOnly(prompt: QuoteExtractionPromptStore.defaultPrompt))

        let messages = RemoteAssetExtractionProvider.promptMessages(
            from: [record],
            configuration: configuration,
            provider: .deepseek
        )

        XCTAssertTrue(messages.system?.contains("金句候选提炼器") == true)
        XCTAssertTrue(messages.system?.contains("普通句子不是 B") == true)
        XCTAssertTrue(messages.system?.contains("独立完整") == true)
        XCTAssertTrue(messages.system?.contains("判断密度") == true)
        XCTAssertTrue(messages.system?.contains("口水话") == true)
        XCTAssertTrue(messages.system?.contains("反差结构") == true)
        XCTAssertTrue(messages.system?.contains("明确讨论对象") == true)
        XCTAssertTrue(messages.system?.contains("对象不清的半句话不要输出") == true)
        XCTAssertTrue(messages.system?.contains("他们是谁") == true)
        XCTAssertTrue(messages.system?.contains("和什么一样") == true)
        XCTAssertTrue(messages.system?.contains("你改变他们，很难代价会很大") == true)
        XCTAssertTrue(messages.system?.contains("赚钱也是一样") == true)
        XCTAssertTrue(messages.system?.contains("这句话是什么") == true)
        XCTAssertTrue(messages.system?.contains("这个增强回路是什么") == true)
        XCTAssertTrue(messages.system?.contains("但是创业了七年，我才明白这句话是大错特错") == true)
        XCTAssertTrue(messages.system?.contains("情绪强烈不等于对象明确") == true)
        XCTAssertTrue(messages.system?.contains("局部方案批评不是金句") == true)
        XCTAssertTrue(messages.system?.contains("百分之九十九的生意都能通用这个增强回路") == true)
        XCTAssertTrue(messages.system?.contains("案例叙述不是金句") == true)
        XCTAssertTrue(messages.system?.contains("家庭是个系统。那有些家庭的目标就是") == true)
        XCTAssertTrue(messages.system?.contains("案例段落、解释段落、铺垫段落") == true)
        XCTAssertTrue(messages.system?.contains("数据钩子、转场句、提问引子") == true)
        XCTAssertTrue(messages.system?.contains("有用的信息不等于金句") == true)
        XCTAssertTrue(messages.system?.contains("值得用户二次编辑") == true)
        XCTAssertTrue(messages.system?.contains("对象明确的价值排序句可以判 A") == true)
        XCTAssertTrue(messages.system?.contains("对标、方法、流程、策略不是天然淘汰") == true)
        XCTAssertTrue(messages.system?.contains("产品决策硬排除") == true)
        XCTAssertTrue(messages.system?.contains("课程、交付方式、功能设计、页面交互") == true)
        XCTAssertTrue(messages.system?.contains("“标品”“零边际成本”“用户自定义提炼什么”") == true)
        XCTAssertTrue(messages.system?.contains("内部产品配置、项目执行建议、团队协作安排") == true)
        XCTAssertTrue(messages.system?.contains("B 是高潜素材，不是普通句子、有用句子、案例段落、解释段落、铺垫段落") == true)
        XCTAssertTrue(messages.user.contains("真正能复用的不是模板"))
    }

    func testCustomRecipePromptMessagesExposeRecipeGoalAndRules() {
        let record = HistoryRecord(
            id: "r-custom",
            createdAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 1,
            rawText: "原始文本",
            processingMode: "直出",
            processedText: nil,
            finalText: "今天要整理一个待办清单，然后写一份工作日报。",
            status: "completed",
            characterCount: 22
        )
        let recipe = ExtractionRecipe.custom(
            id: "custom.creator-review",
            name: "创作复盘",
            recipeDescription: "提炼创作复盘内容",
            goalPrompt: "只整理今天与内容创作有关的行动和复盘。",
            outputKind: .summary,
            processingStrategy: .whole,
            sourcePolicy: .citedSummary,
            outputSchema: "summary: {title, body, source_record_ids}",
            qualityRules: "每个结论都要能追溯到原始记录。",
            destination: .resultArchive
        )

        let messages = RemoteRecipeExtractionProvider.promptMessages(
            from: [record],
            recipe: recipe,
            configuration: AssetExtractionConfiguration
                .recent(limit: 10)
                .applying(recipeID: recipe.id),
            provider: .deepseek
        )

        XCTAssertTrue(messages.system?.contains("创作复盘") == true)
        XCTAssertTrue(messages.system?.contains("只整理今天与内容创作有关的行动和复盘") == true)
        XCTAssertTrue(messages.system?.contains("每个结论都要能追溯到原始记录") == true)
        XCTAssertTrue(messages.user.contains("id: r-custom"))
        XCTAssertTrue(messages.user.contains("今天要整理一个待办清单"))
    }
}
