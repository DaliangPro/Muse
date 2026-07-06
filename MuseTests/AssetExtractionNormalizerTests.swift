import XCTest
@testable import Muse

final class AssetExtractionNormalizerTests: XCTestCase {

    func testNormalizeCandidatesKeepsCreatorFieldsAndFiltersInvalidTypes() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "为什么收藏了很多爆款模板，还是写不出自己的爆款？",
                status: "completed",
                characterCount: 24
            )
        ]

        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .question,
                    grade: .a,
                    title: "为什么收藏模板写不出爆款？",
                    content: "为什么收藏了很多爆款模板，还是写不出自己的爆款？",
                    summary: "好问题",
                    reason: "有明确痛点和讨论度",
                    scenes: ["标题选题", "开头钩子"],
                    audiences: ["内容创作者"],
                    ruleHit: "好问题规则",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                ),
                AssetExtractionCandidate(
                    type: .term,
                    grade: .a,
                    title: "旧术语",
                    content: "旧术语",
                    summary: nil,
                    reason: "旧类型不进入候选池",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.assetType, .question)
        XCTAssertEqual(candidates.first?.grade, .a)
        XCTAssertEqual(candidates.first?.reason, "有明确痛点和讨论度")
        XCTAssertEqual(candidates.first?.scenes, ["标题选题", "开头钩子"])
        XCTAssertEqual(candidates.first?.audiences, ["内容创作者"])
        XCTAssertEqual(candidates.first?.status, .pending)
    }

    func testNormalizeCandidatesKeepsMoreThanTwentyValuableCandidates() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: (0..<25).map { "真正能复用的是自己的判断路径 \($0)" }.joined(separator: "，"),
                status: "completed",
                characterCount: 8
            )
        ]
        let assets = (0..<25).map { index in
            AssetExtractionCandidate(
                type: .viewpoint,
                grade: .b,
                title: "观点 \(index)",
                content: "真正能复用的是自己的判断路径 \(index)",
                summary: nil,
                reason: "有明确复用价值",
                keywords: [],
                sourceRecordIDs: ["r1"]
            )
        }

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: AssetExtractionResult(assets: assets),
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertEqual(candidates.count, 25)
    }

    func testNormalizeRemovesDuplicateAndResolvesSourceIDs() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本 1",
                processingMode: nil,
                processedText: nil,
                finalText: "真正能复用的是自己的判断路径",
                status: "completed",
                characterCount: 3
            ),
            HistoryRecord(
                id: "r2",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本 2",
                processingMode: nil,
                processedText: nil,
                finalText: "真正能复用的是另一条判断路径",
                status: "completed",
                characterCount: 3
            )
        ]

        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "同一条标题",
                    content: "真正能复用的是自己的判断路径",
                    summary: "摘要一",
                    keywords: ["方法", "方法"],
                    sourceRecordIDs: ["r1", "r404"]
                ),
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "同一条标题",
                    content: "真正能复用的是自己的判断路径",
                    summary: "摘要二",
                    keywords: [],
                    sourceRecordIDs: []
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.sourceRecordIDs, ["r1"])
    }

    func testNormalizeSkipsCandidatesWithoutValidSourceIDs() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "旧内容，新内容",
                status: "completed",
                characterCount: 2
            )
        ]
        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "无来源标题",
                    content: "无来源观点",
                    summary: nil,
                    keywords: [],
                    sourceRecordIDs: ["missing"]
                ),
                AssetExtractionCandidate(
                    type: .question,
                    grade: .b,
                    title: "空来源标题",
                    content: "空来源问题",
                    summary: nil,
                    keywords: [],
                    sourceRecordIDs: []
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    /// 改造方案 #1：库内既有内容键打底，跨任务重复产出不再二次入池
    func testNormalizeCandidatesSkipsExistingKeys() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "真正能复用的是已有判断路径，真正能复用的是新的判断路径。",
                status: "completed",
                characterCount: 2
            )
        ]
        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "旧标题",
                    content: "真正能复用的是已有判断路径",
                    summary: nil,
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                ),
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "新标题",
                    content: "真正能复用的是新的判断路径",
                    summary: nil,
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1",
            existingKeys: ["viewpoint|旧标题|真正能复用的是已有判断路径"]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.title, "新标题")
    }

    func testNormalizeKeepsSourceBackedQuotesWithoutSubjectiveQualityJudgment() {
        let strongQuote = "真正能复用的不是模板，而是你的判断路径。"
        let plainSentence = "这个事是一个符合人天性，不需要努力就自然呈现了一个增强回路。"
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "\(plainSentence)\(strongQuote)",
                status: "completed",
                characterCount: plainSentence.count + strongQuote.count
            )
        ]

        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .quote,
                    grade: .b,
                    title: "普通短句",
                    content: plainSentence,
                    summary: nil,
                    reason: "只是一个句子，不该当金句",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                ),
                AssetExtractionCandidate(
                    type: .quote,
                    grade: .a,
                    title: "判断路径",
                    content: strongQuote,
                    summary: nil,
                    reason: "有反差和判断力度",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.content), [plainSentence, strongQuote])
    }

    func testNormalizeKeepsSourceBackedViewpointsWithoutSubjectiveQualityJudgment() {
        let texts = [
            "总而言之，就是提炼出来的东西都是不对的。",
            "其次就是好观点，好观点里面有很多，也是它的总结。",
            "第三个就是表达框架提炼出来的，根本也不是框架呀。"
        ]
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: texts.joined(separator: ""),
                status: "completed",
                characterCount: texts.joined().count
            )
        ]

        let result = AssetExtractionResult(
            assets: texts.enumerated().map { index, text in
                AssetExtractionCandidate(
                    type: .viewpoint,
                    grade: .b,
                    title: "上下文依赖观点 \(index)",
                    content: text,
                    summary: nil,
                    reason: "只是上下文里的测试反馈",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            }
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.map(\.content), texts)
    }

    func testNormalizeSkipsGeneratedContentNotFoundInSource() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "我只是提炼语料资产，我没有要让大模型回答我这个问题。",
                status: "completed",
                characterCount: 25
            )
        ]

        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .quote,
                    grade: .a,
                    title: "提炼不是代写",
                    content: "真正的语料资产来自原文，而不是模型的二次创作。",
                    summary: nil,
                    reason: "听起来像金句，但原文没有说过",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testNormalizeSkipsQuestionWhenContentIsGeneratedAnswerEvenIfTitleMatchesSource() {
        let question = "我只是提炼语料资产，我没有要让大模型回答我这个问题吗？"
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: question,
                status: "completed",
                characterCount: question.count
            )
        ]

        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .question,
                    grade: .b,
                    title: question,
                    content: "你应该只提炼原始问题，不应该让模型回答它。",
                    summary: nil,
                    reason: "原问题值得保留",
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testNormalizeSkipsCandidatesWithoutExplicitGrade() {
        let records = [
            HistoryRecord(
                id: "r1",
                createdAt: Date(),
                durationSeconds: 2,
                rawText: "原始文本",
                processingMode: nil,
                processedText: nil,
                finalText: "一个可能有价值的观点",
                status: "completed",
                characterCount: 10
            )
        ]
        let result = AssetExtractionResult(
            assets: [
                AssetExtractionCandidate(
                    type: .viewpoint,
                    title: "缺失等级",
                    content: "一个可能有价值的观点",
                    summary: nil,
                    keywords: [],
                    sourceRecordIDs: ["r1"]
                )
            ]
        )

        let candidates = AssetExtractionNormalizer().normalizeCandidates(
            result: result,
            sourceRecords: records,
            extractionJobID: "job-1"
        )

        XCTAssertTrue(candidates.isEmpty)
    }
}

final class AssetExtractionLowValueFilterTests: XCTestCase {

    /// 改造方案 #10：重复语气词不再漏网，真实内容不误伤
    func testLowValueDetection() async {
        let service = AssetExtractionService()

        let lowValue = ["好的", "好的好的", "嗯嗯", "嗯嗯嗯", "OK", "okok", "哈哈哈哈", "。。。", "  "]
        for text in lowValue {
            let result = await service.isLikelyLowValue(text)
            XCTAssertTrue(result, "应判定为低价值: \(text)")
        }

        let realContent = ["慢就是快", "好的，我下午三点把方案发给你", "嗯，这个观点我不同意", "OK，整体方向定了", "收藏模板只是在保存别人的结果"]
        for text in realContent {
            let result = await service.isLikelyLowValue(text)
            XCTAssertFalse(result, "不应误伤真实内容: \(text)")
        }
    }
}
