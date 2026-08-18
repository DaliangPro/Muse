import XCTest
@testable import Muse

final class VoicePolishCoreTests: XCTestCase {

    func testRouterUsesDeterministicCorrectionAndSideNoteSignals() {
        XCTAssertEqual(route("今天下午把方案发出去。"), .fast)
        XCTAssertEqual(route("今天发方案，不对，明天发。"), .structured)
        XCTAssertEqual(route("先发方案，不对，我改一下，应该是明天发。"), .deep)
        XCTAssertEqual(route("顺便说一下，预算也要再确认。"), .structured)
        XCTAssertEqual(route("这句不用写，只是给你解释背景。"), .deep)
        XCTAssertEqual(route("还有一项，发布前补回归测试。"), .deep)
        XCTAssertEqual(route("第一，写方案。第二，补测试。"), .fast)
        XCTAssertEqual(route("I mean, ship it tomorrow."), .structured)
        XCTAssertEqual(route("Scratch that. I mean, ship it Friday."), .deep)
    }

    func testRouterUsesSharedTopicSwitchEvidenceAndPlansUnsafeListContracts() {
        XCTAssertEqual(
            route("请把另外一个问题的答案也补充到同一份报告中，保持原有章节顺序和所有引用内容不变，完成后直接发给客户确认。"),
            .fast
        )
        XCTAssertEqual(
            route("另外一个问题是测试还没完成，我们需要重新确认上线时间。"),
            .deep
        )
        XCTAssertEqual(
            route(
                "步骤包括：for i in a; do echo i; done",
                requirements: "请使用数字列表。",
                scene: .workChat
            ),
            .structured
        )
    }

    func testRouterDoesNotUseLengthAloneToAddASecondModelCall() {
        XCTAssertEqual(route(String(repeating: "中", count: 120)), .fast)
        XCTAssertEqual(route(String(repeating: "中", count: 121)), .fast)
        XCTAssertEqual(route(String(repeating: "中", count: 501)), .fast)
        XCTAssertEqual(route(Array(repeating: "word", count: 80).joined(separator: " ")), .fast)
        XCTAssertEqual(route(Array(repeating: "word", count: 81).joined(separator: " ")), .fast)
        XCTAssertEqual(route(Array(repeating: "word", count: 301).joined(separator: " ")), .fast)
    }

    func testRouterDoesNotUseProviderSegmentCountAloneToAddASecondModelCall() {
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: "今天整理方案。明天发给团队。",
                segments: [segment("今天整理方案。"), RecognitionSegment(
                    id: "s2",
                    text: "明天发给团队。",
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: .phaseOneUnknown,
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
        )

        let decision = VoicePolishComplexityRouter.decide(request: request, factCandidates: [])

        XCTAssertEqual(decision.route, .fast)
    }

    func testAutomaticModeUsesReliableTextProtocolWhileKeepingContentDiagnosis() {
        let simple = makeRequest("今天下午把方案发出去。")
        let enumeration = makeRequest("第一，写方案。第二，补测试。")
        let structured = makeRequest("顺便说一下，预算也要再确认。")
        let deep = makeRequest("先用红色，不对，我改一下，应该是蓝色。")

        XCTAssertEqual(executedRoute(simple, quality: .automatic), .fast)
        XCTAssertEqual(executedRoute(enumeration, quality: .automatic), .fast)
        XCTAssertEqual(executedRoute(structured, quality: .automatic), .fast)
        XCTAssertEqual(executedRoute(deep, quality: .automatic), .fast)

        // 旧档位只用于兼容历史数据和既有确定性测试；正式设置读取会统一迁移
        // 到 automatic，不能再让用户的旧选择改变生产行为。
        XCTAssertEqual(executedRoute(enumeration, quality: .fast), .fast)
        XCTAssertEqual(executedRoute(enumeration, quality: .balanced), .fast)
        XCTAssertEqual(executedRoute(enumeration, quality: .quality), .deep)
        XCTAssertEqual(executedRoute(simple, quality: .fast), .fast)
        XCTAssertEqual(executedRoute(structured, quality: .fast), .fast)
        XCTAssertEqual(executedRoute(deep, quality: .fast), .fast)
        XCTAssertEqual(executedRoute(structured, quality: .balanced), .fast)
        XCTAssertEqual(executedRoute(deep, quality: .balanced), .fast)
        XCTAssertEqual(executedRoute(structured, quality: .quality), .structured)
        XCTAssertEqual(executedRoute(deep, quality: .quality), .deep)
    }

    func testChineseNumberCanonicalizationCoversColloquialTailUnits() {
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一万六千八"), "16800")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一万六"), "16000")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("四万八"), "48000")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一千六"), "1600")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一百六"), "160")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一六八零零"), "16800")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("负一百六"), "-160")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("三点五"), "3.5")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一百零六"), "106")
        XCTAssertEqual(ProtectedFactExtractor.canonicalChineseNumber("一万零六"), "10006")
    }

    func testChineseClockTimeAndArabicRenderingShareCanonicalFact() {
        let sourceFacts = ProtectedFactExtractor.extract(from: [
            segment("安装包签名截止下周一十点，周四下午三点半复核。"),
        ])
        let outputFacts = ProtectedFactExtractor.extract(from: [
            segment("安装包签名截止下周一上午 10:00，周四下午 3:30 复核。"),
        ])

        let sourceTimes = Set(sourceFacts.filter { $0.kind == .time }.compactMap(\.canonicalValue))
        let outputTimes = Set(outputFacts.filter { $0.kind == .time }.compactMap(\.canonicalValue))
        XCTAssertEqual(sourceTimes, ["下周一|10:00", "周四|15:30"])
        XCTAssertEqual(outputTimes, sourceTimes)

        let ambiguous = ProtectedFactExtractor.extract(from: [segment("这里有十点建议。")])
        XCTAssertFalse(ambiguous.contains { $0.kind == .time })
    }

    func testRelativeDayRemainsPartOfClockFactAndCorrection() {
        let wrongDay = makeRequest("会议安排在今天十点。", scene: .workChat)
        let wrongDayFacts = ProtectedFactExtractor.extract(from: wrongDay.input.segments)
        let wrongDayValidation = VoicePolishValidator.validateFast(
            output: "会议安排在明天十点。",
            request: wrongDay,
            sourceFacts: wrongDayFacts
        )
        XCTAssertTrue(wrongDayValidation.codes.contains(.missingProtectedFact))
        XCTAssertTrue(wrongDayValidation.codes.contains(.planIntegrityFailure))

        let correction = makeRequest(
            "我说错了，不是今天十点，是明天十点。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: correction.input.segments)
        XCTAssertEqual(
            Set(facts.filter { $0.kind == .time }.compactMap(\.canonicalValue)),
            ["今天|10:00", "明天|10:00"]
        )
        let validation = VoicePolishValidator.validateFast(
            output: "会议时间是明天十点。",
            request: correction,
            sourceFacts: facts
        )
        XCTAssertFalse(
            validation.hasHardFailure,
            "明确改口后只保留最终日期时间应通过：\(validation.codes)"
        )

        let bareCorrection = makeRequest("人数不是 3 人，是 4 人。", scene: .workChat)
        let bareFacts = ProtectedFactExtractor.extract(from: bareCorrection.input.segments)
        let bareValidation = VoicePolishValidator.validateFast(
            output: "人数为 4 人。",
            request: bareCorrection,
            sourceFacts: bareFacts
        )
        XCTAssertFalse(
            bareValidation.hasHardFailure,
            "裸‘不是 A，是 B’也必须只保留最终事实：\(bareValidation.codes)"
        )

        for uncertainSource in [
            "人数不是 3 人，是 4 人吗？",
            "人数不是 3 人，是 4 人吗",
            "如果人数不是 3 人，是 4 人，就换会议室。",
            "有人问：“人数不是 3 人，是 4 人？”",
        ] {
            let uncertain = makeRequest(uncertainSource, scene: .workChat)
            let uncertainFacts = ProtectedFactExtractor.extract(from: uncertain.input.segments)
            let uncertainSuperseded = VoicePolishValidator.locallySupersededFactIndices(
                request: uncertain,
                sourceFacts: uncertainFacts
            )
            let threeIndex = try! XCTUnwrap(uncertainFacts.firstIndex {
                $0.kind == .number && $0.canonicalValue == "3"
            })
            XCTAssertFalse(
                uncertainSuperseded.contains(threeIndex),
                "疑问、假设或引语不能被改写成确定事实：\(uncertainSource)"
            )
        }
    }

    func testRepeatedRelativeTimeInsideExplicitCorrectionIsFullySuperseded() {
        let request = makeRequest(
            "明天下午三点我们去客户公司开会我说错了不是明天下午三点是后天下午四点地点在客户公司一楼会议室不对刚才地点也说错了是在二楼会议室",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let supersededOccurrences = VoicePolishValidator.locallySupersededFactOccurrences(
            request: request,
            sourceFacts: facts
        )
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldIndex = try! XCTUnwrap(facts.firstIndex {
            $0.kind == .time && $0.canonicalValue == "明天|15:00"
        })
        let factDescriptions = facts.map {
            "\($0.kind.rawValue):\($0.sourceText):\($0.canonicalValue ?? "nil")"
        }
        XCTAssertTrue(
            superseded.contains(oldIndex),
            "facts=\(factDescriptions) occurrences=\(supersededOccurrences) superseded=\(superseded)"
        )

        let validation = VoicePolishValidator.validateFast(
            output: "后天下午四点，我们去客户公司二楼会议室开会。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(
            validation.codes.contains(.missingProtectedFact),
            "codes=\(validation.codes) superseded=\(superseded)"
        )
    }

    func testLabeledBudgetWithoutCurrencyAndRenderedAmountShareCanonicalFact() {
        let source = makeRequest(
            "预算先按一万六千八准备，这句在前面，我改一下，最终预算是一万六。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: source.input.segments)
        let amountValues = facts.filter { $0.kind == .amount }.compactMap(\.canonicalValue)

        XCTAssertTrue(amountValues.contains("16800"))
        XCTAssertTrue(amountValues.contains("16000"))

        let validation = VoicePolishValidator.validateFast(
            output: "最终预算为 16,000 元。",
            request: source,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.codes.contains(.missingProtectedFact), "\(validation.codes)")
        XCTAssertFalse(validation.codes.contains(.planIntegrityFailure), "\(validation.codes)")

        let unlabeled = ProtectedFactExtractor.extract(from: [segment("本轮共有三项预算问题。")])
        XCTAssertFalse(unlabeled.contains { $0.kind == .amount })
    }

    func testParagraphOnlyChangeDoesNotCountAsSubstantiveLongDraftPolish() {
        let source = "最近重新整理语音输入后，我开始更关注成稿能不能直接发送。以前只看识别是否完整，现在还会检查最终意图是否唯一。长文本如果完全不分段，事实都在也很难阅读。上下文可以帮助纠正产品名，但不能带入旁边无关的私人信息。修改后的文字还要保留原来的直接语气，不能自动变成客服模板。"
        let request = makeRequest(source, scene: .document)
        let output = "最近重新整理语音输入后，我开始更关注成稿能不能直接发送。\n\n以前只看识别是否完整，现在还会检查最终意图是否唯一。\n\n长文本如果完全不分段，事实都在也很难阅读。\n\n上下文可以帮助纠正产品名，但不能带入旁边无关的私人信息。\n\n修改后的文字还要保留原来的直接语气，不能自动变成客服模板。"
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).kind, .paragraphs)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts
        )
        XCTAssertTrue(validation.codes.contains(.unchangedDraft), "\(validation.codes)")
    }

    func testParagraphOnlyChangeStillRejectsRetainedLongDraftDisfluencies() {
        let source = "嗯我我先说一下这次复盘的情况，目前页面已经检查过一遍。这个这个登录流程还要继续核对，支付页也需要再看一下。呃后面还要和研发确认上线时间，暂时没有新的承诺。最后请保持原来的直接语气，不要自动补一个漂亮结论。"
        let request = makeRequest(source, scene: .document)
        let output = "嗯我我先说一下这次复盘的情况，目前页面已经检查过一遍。\n\n这个这个登录流程还要继续核对，支付页也需要再看一下。\n\n呃后面还要和研发确认上线时间，暂时没有新的承诺。最后请保持原来的直接语气，不要自动补一个漂亮结论。"
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts
        )
        XCTAssertTrue(validation.codes.contains(.unchangedDraft), "\(validation.codes)")
    }

    func testDeferredSearchMentionDoesNotReversePreservedNegativeAction() {
        let source = "这版先不要做复杂搜索先把结果列表和筛选做稳定搜索放到后面不是这版范围"
        let request = makeRequest(source, scene: .note)
        let output = "第一版先不做复杂搜索，先把结果列表和筛选功能做稳定。搜索功能放到后面，不在这一版范围内。"

        XCTAssertTrue(
            VoicePolishValidator.protectedNegativeIntentFailures(
                output: output,
                request: request
            ).isEmpty
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.codes.contains(.missingProtectedFact), "\(validation.codes)")

        let reversed = VoicePolishValidator.protectedNegativeIntentFailures(
            output: "第一版不做搜索，但搜索功能同步开发。",
            request: request
        )
        XCTAssertFalse(reversed.isEmpty)
    }

    func testExplicitNamedRetractionBindsUniqueDistantRetryCount() {
        let filler = String(repeating: "这里继续说明流程边界和验收要求", count: 80)
        let request = makeRequest(
            "质量修复重试次数先按三次记录\(filler)前面质量修复的重试次数我说错了最终最多两次",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let old = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "3" })
        XCTAssertTrue(superseded.contains(old))

        let valid = VoicePolishValidator.validateFast(
            output: "\(filler)\n\n质量修复的重试次数最终最多两次。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(valid.hasHardFailure, "\(valid.codes)")

        let invalid = VoicePolishValidator.validateFast(
            output: "\(filler)\n\n质量修复仍按三次，最终最多两次。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertTrue(invalid.codes.contains(.supersededFactRetained), "\(invalid.codes)")
    }

    func testFactExtractorKeepsAmountPercentageVersionDateAndAddressSemantics() {
        let text = "报价 4.98 万，折扣 12.5%，版本 v2.1.0，日期 2026-07-31，发到 test@example.com，详情 https://example.com/a。"
        let facts = ProtectedFactExtractor.extract(from: [segment(text)])

        XCTAssertTrue(facts.contains { $0.kind == .amount && $0.canonicalValue == "49800" })
        XCTAssertTrue(facts.contains { $0.kind == .percentage && $0.canonicalValue == "12.5%" })
        XCTAssertTrue(facts.contains { $0.kind == .version && $0.canonicalValue == "v2.1.0" })
        XCTAssertTrue(facts.contains { $0.kind == .date && $0.canonicalValue == "2026-07-31" })
        XCTAssertTrue(facts.contains { $0.kind == .email && $0.canonicalValue == "test@example.com" })
        XCTAssertTrue(facts.contains { $0.kind == .url && $0.canonicalValue == "https://example.com/a" })
    }

    func testFactExtractorKeepsChineseMonthDayAndCleanFilePaths() {
        let facts = ProtectedFactExtractor.extract(from: [segment(
            "发布日期从八月二十日改到 8 月 28 日，运行 scripts/package-app.sh，产物在 build/Muse.app，中文文件在 /Users/jiliang/文档/课程.md，素材在“/Users/jiliang/课程 素材/第一章.md”，再检查 /Applications；P50/P95 只是性能指标。"
        )])

        XCTAssertTrue(facts.contains { $0.kind == .date && $0.canonicalValue == "08-20" })
        XCTAssertTrue(facts.contains { $0.kind == .date && $0.canonicalValue == "08-28" })
        XCTAssertTrue(facts.contains { $0.kind == .filePath && $0.canonicalValue == "scripts/package-app.sh" })
        XCTAssertTrue(facts.contains { $0.kind == .filePath && $0.canonicalValue == "build/Muse.app" })
        XCTAssertTrue(facts.contains { $0.kind == .filePath && $0.canonicalValue == "/Users/jiliang/文档/课程.md" })
        XCTAssertTrue(facts.contains { $0.kind == .filePath && $0.canonicalValue == "/Users/jiliang/课程 素材/第一章.md" })
        XCTAssertTrue(facts.contains { $0.kind == .filePath && $0.canonicalValue == "/Applications" })
        XCTAssertFalse(facts.contains { $0.kind == .filePath && $0.sourceText.contains("P50/P95") })
    }

    func testFactExtractorDeduplicatesSameSemanticFactWithinOneSegment() {
        let facts = ProtectedFactExtractor.extract(from: [
            segment("预算 49,800 元，最后仍按 4.98 万执行。"),
        ])

        XCTAssertEqual(
            facts.filter { $0.kind == .amount && $0.canonicalValue == "49800" }.count,
            1
        )
    }

    func testFactExtractorKeepsBoundedSingleDigitsAndSpacedChineseAmount() {
        let facts = ProtectedFactExtractor.extract(from: [segment(
            "数据只有九个月，至少看五个主流产品，给三条可验证建议，合同总金额是四 万八。"
        )])

        XCTAssertTrue(facts.contains { $0.kind == .number && $0.canonicalValue == "9" })
        XCTAssertTrue(facts.contains { $0.kind == .number && $0.canonicalValue == "5" })
        XCTAssertTrue(facts.contains { $0.kind == .number && $0.canonicalValue == "3" })
        XCTAssertTrue(facts.contains { $0.kind == .amount && $0.canonicalValue == "48000" })

        let generic = ProtectedFactExtractor.extract(from: [segment("记录一个 bug。")])
        XCTAssertFalse(generic.contains { $0.kind == .number && $0.canonicalValue == "1" })

        let rewrittenCounters = ProtectedFactExtractor.extract(from: [segment(
            "至少看 5 款产品，给出 3 项建议，共 6 人参加。"
        )])
        XCTAssertTrue(rewrittenCounters.contains { $0.kind == .number && $0.canonicalValue == "5" })
        XCTAssertTrue(rewrittenCounters.contains { $0.kind == .number && $0.canonicalValue == "3" })
        XCTAssertTrue(rewrittenCounters.contains { $0.kind == .number && $0.canonicalValue == "6" })

        let semanticCounters = ProtectedFactExtractor.extract(from: [segment(
            "创作者可以选择三个任务路径，新章节必须双人批准，但不要压成十几行摘要。"
        )])
        XCTAssertTrue(semanticCounters.contains { $0.kind == .number && $0.canonicalValue == "3" })
        XCTAssertTrue(semanticCounters.contains { $0.kind == .number && $0.canonicalValue == "2" })
        XCTAssertFalse(semanticCounters.contains { $0.kind == .number && $0.canonicalValue == "10" })
    }

    func testStructuredDecoderAcceptsFencePrefixThinkUnicodeAndTrailingComma() throws {
        let value = SimplePayload(message: "你好")
        let json = try encoded(value)
        let response = """
        <think>不应暴露</think>
        结果如下：
        ```json
        \(json.dropLast()),}
        ```
        """

        let decoded = try StructuredLLMDecoder.decode(SimplePayload.self, from: response)

        XCTAssertEqual(decoded, value)
    }

    func testStructuredDecoderRejectsMultipleObjectsAndOversizedResponse() {
        XCTAssertThrowsError(
            try StructuredLLMDecoder.decode(SimplePayload.self, from: #"{"message":"一"} {"message":"二"}"#)
        ) { error in
            XCTAssertEqual(error as? StructuredLLMDecoderError, .ambiguousJSONObjects)
        }
        XCTAssertThrowsError(
            try StructuredLLMDecoder.decode(
                SimplePayload.self,
                from: String(repeating: "x", count: 50),
                maximumBytes: 10
            )
        ) { error in
            XCTAssertEqual(error as? StructuredLLMDecoderError, .responseTooLarge)
        }
    }

    func testCharacterSafetyNormalizesLineEndingsAndPreservesTextCharacters() {
        let safe = "第一行\r\n第二行\t👨‍👩‍👧‍👦e\u{301}"
        XCTAssertFalse(VoicePolishCharacterSafety.containsUnsafeCharacters(safe))
        XCTAssertEqual(
            VoicePolishCharacterSafety.sanitizedFallback(safe),
            "第一行\n第二行\t👨‍👩‍👧‍👦e\u{301}"
        )

        let unsafe = String(decoding: [
            0x41, 0x00, 0x1B, 0x7F, 0xC2, 0x85, 0xEF, 0xB7, 0x90, 0x42,
        ], as: UTF8.self)
        XCTAssertTrue(VoicePolishCharacterSafety.containsUnsafeCharacters(unsafe))
        XCTAssertEqual(VoicePolishCharacterSafety.sanitizedFallback(unsafe), "AB")
    }

    func testWritingContextClearsBodyUnlessExplicitlySafeAndAuthorized() {
        let unknown = WritingContext(
            scene: .email,
            level: .nearbyText,
            safety: .unknown,
            selectedText: "秘密",
            textBeforeCursor: "前文",
            textAfterCursor: "后文"
        )
        XCTAssertNil(unknown.selectedText)
        XCTAssertNil(unknown.textBeforeCursor)
        XCTAssertNil(unknown.textAfterCursor)

        let metadataOnly = WritingContext(
            scene: .email,
            level: .metadataOnly,
            safety: .safe,
            selectedText: "仍不得读取"
        )
        XCTAssertNil(metadataOnly.selectedText)
    }

    func testContextSafetyUsesStrictAllowlistAndExplicitSecureChecks() {
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextField",
                subrole: "AXStandardTextField",
                editable: true,
                protectedContent: false
            ),
            .safe
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                editable: true,
                protectedContent: true
            ),
            .secure
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXWebArea",
                subrole: "AXStandardWindow",
                editable: true,
                protectedContent: false
            ),
            .unknown
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextArea",
                subrole: nil,
                editable: true,
                protectedContent: false
            ),
            .unknown
        )
        XCTAssertEqual(
            WritingContextCapture.safetyForTesting(
                role: "AXTextArea",
                subrole: "AXStandardTextArea",
                editable: true,
                protectedContent: nil
            ),
            .unknown
        )
    }

    func testSceneClassifierHonorsOverridesAndDoesNotGuessBrowserPages() {
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.google.Chrome",
                focusedRole: "AXTextField"
            ),
            .unknown
        )
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.google.Chrome",
                focusedRole: "AXTextField",
                userOverrides: ["com.google.Chrome": .aiPrompt]
            ),
            .aiPrompt
        )
        XCTAssertEqual(
            AppSceneClassifier.classify(
                bundleID: "com.apple.mail",
                focusedRole: "AXTextArea"
            ),
            .email
        )
    }

    func testPromptPayloadCannotCarryUnauthorizedContextBody() throws {
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: "请回复确认。",
                segments: [segment("请回复确认。")],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(
                applicationBundleID: "com.apple.mail",
                scene: .email,
                level: .nearbyText,
                safety: .unknown,
                selectedText: "未授权秘密",
                textBeforeCursor: "未授权前文",
                textAfterCursor: "未授权后文"
            ),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
        )

        let payload = try VoicePolishPrompts.payload(
            for: request,
            sourceFacts: [],
            deepDeferred: false
        )

        XCTAssertFalse(payload.contains("未授权秘密"))
        XCTAssertFalse(payload.contains("未授权前文"))
        XCTAssertFalse(payload.contains("未授权后文"))
        XCTAssertTrue(payload.contains(#""level":"nearbyText""#))
        XCTAssertTrue(payload.contains(#""safety":"unknown""#))
    }

    func testVoicePolishSettingsDefaultsArePrivacyPreserving() {
        let suite = "VoicePolishSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VoicePolishSettings.qualityMode(defaults: defaults), .automatic)
        XCTAssertEqual(VoicePolishSettings.contextLevel(defaults: defaults), .nearbyText)
        XCTAssertTrue(VoicePolishSettings.personalizationEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
        XCTAssertEqual(VoicePolishSettings.correctionLimit(defaults: defaults), 200)
        XCTAssertNil(VoicePolishSettings.modelOverride(defaults: defaults))
    }

    func testLegacyQualitySelectionsAllMigrateToSingleAutomaticMode() {
        let suite = "VoicePolishSingleModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for legacy in ["fast", "balanced", "quality"] {
            defaults.set(legacy, forKey: DefaultsKeys.voicePolishQualityMode)
            XCTAssertEqual(
                VoicePolishSettings.qualityMode(defaults: defaults),
                .automatic,
                "旧档位 \(legacy) 不得继续改变产品行为"
            )
        }
    }

    func testCrossSegmentCorrectionMarksOnlyOldFactAsSuperseded() {
        let segments = [
            RecognitionSegment(
                id: "s1",
                text: "预算先按 16800 元准备。",
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            ),
            RecognitionSegment(
                id: "s2",
                text: "不对，最终预算改成 16000 元，周五发方案。",
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            ),
        ]
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: segments.map(\.text).joined(),
                segments: segments,
                durationMs: 8_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let facts = ProtectedFactExtractor.extract(from: segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )

        let oldIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16800" })
        let finalIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16000" })
        XCTAssertTrue(superseded.contains(oldIndex))
        XCTAssertFalse(superseded.contains(finalIndex))
    }

    func testExplicitFromToAndDistantCorrectionMarkOnlyOldDate() {
        let direct = makeRequest("发布日期从八月二十日改到 8 月 28 日。")
        let directFacts = ProtectedFactExtractor.extract(from: direct.input.segments)
        let directSuperseded = VoicePolishValidator.locallySupersededFactIndices(
            request: direct,
            sourceFacts: directFacts
        )
        let oldDirect = try! XCTUnwrap(directFacts.firstIndex { $0.canonicalValue == "08-20" })
        let finalDirect = try! XCTUnwrap(directFacts.firstIndex { $0.canonicalValue == "08-28" })
        XCTAssertTrue(directSuperseded.contains(oldDirect))
        XCTAssertFalse(directSuperseded.contains(finalDirect))

        let segments = [
            segment("发布日期先记八月二十日。"),
            RecognitionSegment(id: "s2", text: "中间先说明页面和截图安排。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s3", text: "前面那句改成 8 月 28 日。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
        ]
        let distant = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: segments.map(\.text).joined(),
                segments: segments,
                durationMs: 3_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let distantFacts = ProtectedFactExtractor.extract(from: segments)
        let distantSuperseded = VoicePolishValidator.locallySupersededFactIndices(
            request: distant,
            sourceFacts: distantFacts
        )
        let oldDistant = try! XCTUnwrap(distantFacts.firstIndex { $0.canonicalValue == "08-20" })
        XCTAssertTrue(distantSuperseded.contains(oldDistant))
    }

    func testCorrectionLocatorDoesNotMisreadNotForExternalRelease() {
        let request = makeRequest("v2.0 不对外发布，v2.1 只用于内部测试。", scene: .workChat)
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)
    }

    func testRepeatedSameNumberInDifferentRelationsCannotBeGloballySuperseded() {
        let request = makeRequest(
            "北京 3 人、上海也是 3 人；不对，上海改为 4 人，北京仍是 3 人。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let sharedThree = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "3" })

        XCTAssertFalse(superseded.contains(sharedThree))
        let validation = VoicePolishValidator.validateFast(
            output: "北京仍有 3 人，上海改为 4 人。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.hasHardFailure, "\(validation.codes)")
    }

    func testRewriteInstructionDoesNotSupersedeUnrelatedCodeIdentifier() {
        let request = makeRequest(
            "选题是用 AI 完成真实工作，小林先看逻辑，不要直接改成营销文案。事实核查要看官方页面，涉及 API Key 时一律脱敏。",
            scene: .email
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let aiIndex = try! XCTUnwrap(facts.firstIndex { $0.sourceText == "AI" })

        XCTAssertFalse(
            VoicePolishValidator.locallySupersededFactIndices(
                request: request,
                sourceFacts: facts
            ).contains(aiIndex)
        )
    }

    func testRewriteInstructionDoesNotSupersedeUnrelatedNumbers() {
        let request = makeRequest(
            "这份报告有 3 个问题，把这段改成一分钟口播，再补 2 个例子。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )

        XCTAssertTrue(superseded.isEmpty)
    }

    func testFormatTransformationDoesNotSupersedeQuantitiesWithDifferentObjects() {
        let request = makeRequest(
            "请把这 3 个问题改成 1 张表格。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )

        XCTAssertTrue(superseded.isEmpty)
        let validation = VoicePolishValidator.validateFast(
            output: request.fallbackText,
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.hasHardFailure, "\(validation.codes)")
    }

    func testCorrectionSupersedesOnlyMatchingBudgetAcrossAttachmentPages() {
        let request = makeRequest(
            "预算先按 3 万元。附件共 2 页。不对，最终预算改成 4 万元。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldBudget = try! XCTUnwrap(facts.firstIndex {
            $0.kind == .amount && $0.canonicalValue == "30000"
        })
        let finalBudget = try! XCTUnwrap(facts.firstIndex {
            $0.kind == .amount && $0.canonicalValue == "40000"
        })

        XCTAssertEqual(superseded, [oldBudget])
        XCTAssertFalse(superseded.contains(finalBudget))
        let validation = VoicePolishValidator.validateFast(
            output: "最终预算为 4 万元，附件共 2 页。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.hasHardFailure, "\(validation.codes)")
    }

    func testCorrectionSkipsInterveningSameKindUnrelatedAmount() {
        let request = makeRequest(
            "项目预算先按 3 万元，附件制作费是 2 万元。不对，最终项目预算改成 4 万元。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldBudget = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "30000" })
        let attachmentCost = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "20000" })
        let finalBudget = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "40000" })

        XCTAssertEqual(superseded, [oldBudget])
        XCTAssertFalse(superseded.contains(attachmentCost))
        XCTAssertFalse(superseded.contains(finalBudget))
    }

    func testGenericBudgetCorrectionDoesNotGuessBetweenTwoBudgetObjects() {
        let request = makeRequest(
            "项目预算 3 万元，附件预算 2 万元。不对，预算改成 4 万元。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)
    }

    func testCompactFormatInstructionKeepsQuantitiesWithDifferentObjects() {
        let request = makeRequest(
            "请把这3个问题改成1个表格。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)
    }

    func testSameCanonicalValueCannotBecomeGlobalForbiddenWhenAnotherSegmentStillNeedsIt() {
        let segments = [
            RecognitionSegment(id: "s1", text: "北京 3 人。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s2", text: "上海先按 3 人。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s3", text: "不对，上海改成 4 人。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
        ]
        let text = segments.map(\.text).joined()
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: segments,
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let facts = ProtectedFactExtractor.extract(from: segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )

        XCTAssertEqual(superseded.count, 1)
        XCTAssertTrue(VoicePolishValidator.unambiguouslySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)

        let collapsedSegment = RecognitionSegment(
            id: "s1",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        let collapsedRequest = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: [collapsedSegment],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let collapsedFacts = ProtectedFactExtractor.extract(from: [collapsedSegment])
        XCTAssertEqual(
            VoicePolishValidator.locallySupersededFactOccurrences(
                request: collapsedRequest,
                sourceFacts: collapsedFacts
            ).count,
            1
        )
        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: collapsedRequest,
            sourceFacts: collapsedFacts
        ).isEmpty)

        let good = VoicePolishValidator.validateFast(
            output: "北京安排 3 人，上海最终安排 4 人。",
            request: collapsedRequest,
            sourceFacts: collapsedFacts
        )
        XCTAssertFalse(good.hasHardFailure, "\(good.codes)")

        let wrongRelation = VoicePolishValidator.validateFast(
            output: "北京安排 3 人，上海仍安排 3 人；上海最终安排 4 人。",
            request: collapsedRequest,
            sourceFacts: collapsedFacts
        )
        XCTAssertTrue(wrongRelation.codes.contains(.supersededFactRetained))
    }

    func testRelationGateAcceptsNaturalPeopleUnitsAndRejectsBorrowedOrNonCurrentFacts() {
        let request = makeRequest(
            "北京 3 人。上海先按 3 人。不对，上海改成 4 人。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let relationOccurrence = try! XCTUnwrap(
            VoicePolishValidator.locallySupersededFactOccurrences(
                request: request,
                sourceFacts: facts
            ).first
        )
        XCTAssertEqual(relationOccurrence.relationAnchor, "上海")
        XCTAssertEqual(relationOccurrence.factDescriptor, "人")
        XCTAssertEqual(relationOccurrence.replacementDescriptor, "人")
        for output in [
            "北京安排 3 人；上海安排 4 人。",
            "北京安排 3 位；上海安排 4 位。",
            "北京人数为 3；上海人数为 4。",
            "北京安排 3 人；上海：\n最终安排 4 人。",
        ] {
            let result = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: facts
            )
            XCTAssertFalse(result.hasHardFailure, "\(output): \(result.codes)")
        }

        for output in [
            "- 北京 3 人\n- 上海事项另行说明\n- 4 人",
            "北京仍有 3 人；假如上海安排 4 人，另行讨论。",
            "北京仍有 3 人；如果上海安排 4 人，另行讨论。",
            "北京仍有 3 人；曾经上海安排 4 人，现已撤销。",
            "北京仍有 3 人；上海和北京安排无关，4 人属于北京。",
        ] {
            let result = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: facts
            )
            XCTAssertTrue(result.hasHardFailure, "\(output) 不应通过")
        }
    }

    func testExplicitRetractionObjectBindsOldFactWhenLocalLabelsChange() {
        let request = makeRequest(
            "北京团队先安排 3 个人。上海团队也先安排 3 个人。"
                + "前面上海团队参会人数说错了，上海团队最终安排 4 个人。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let occurrences = VoicePolishValidator.locallySupersededFactOccurrences(
            request: request,
            sourceFacts: facts
        )

        XCTAssertEqual(occurrences.count, 1, "\(occurrences)")
        XCTAssertEqual(occurrences.first?.relationAnchor, "上海团队")

        for output in [
            "北京团队安排 3 人，上海团队安排 4 人。",
            "北京团队人数为 3，上海团队人数为 4。",
            "北京团队 3 人；上海团队：\n最终安排 4 人。",
        ] {
            let result = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: facts
            )
            XCTAssertFalse(result.hasHardFailure, "\(output): \(result.codes)")
        }

        for output in [
            "北京团队安排 4 人，上海团队安排 3 人。",
            "北京团队安排 3 人；如果上海团队安排 4 人，就再扩会议室。",
            "北京团队安排 3 人；有人说上海团队安排 4 人，但尚未确认。",
            "北京团队 3 人。4 人不属于上海团队，只是总人数。",
        ] {
            let result = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: facts
            )
            XCTAssertTrue(result.hasHardFailure, "\(output): \(result.codes)")
        }
    }

    func testLocalPostProcessorNeverDeletesRecipientFacingNegation() {
        for source in [
            "给开发说：先别改路径和命令，先只检查配置。",
            "这个功能目前不是坏了，是需要重新授权。",
        ] {
            let request = makeRequest(source, scene: .workChat)
            XCTAssertNil(
                VoicePolishValidator.removingDeterministicDraftArtifacts(
                    from: source,
                    request: request
                )
            )
            let result = VoicePolishValidator.validateFast(
                output: source,
                request: request,
                sourceFacts: ProtectedFactExtractor.extract(from: request.input.segments)
            )
            XCTAssertFalse(result.hasHardFailure, "\(source): \(result.codes)")
        }
    }

    func testShortRestartAndBareCorrectionCannotPassWithPunctuationOnly() {
        for pair in [
            ("可可以发了", "可，可以发了。"),
            ("功功能打不开", "功，功能打不开。"),
            ("周五周五发", "周五，周五发。"),
            ("我选红色，不对，蓝色", "我选红色，不对，蓝色。"),
            ("我先去办公室，不对，去客户那边", "我先去办公室，不对，去客户那边。"),
        ] {
            let request = makeRequest(pair.0, scene: .chat)
            let result = VoicePolishValidator.validateFast(
                output: pair.1,
                request: request,
                sourceFacts: ProtectedFactExtractor.extract(from: request.input.segments)
            )
            XCTAssertTrue(result.hasHardFailure, "\(pair): \(result.codes)")
        }
    }

    func testCorrectionMeaningIsInvariantAcrossProviderSegmentPartitions() {
        let texts = [
            ["预算先按 16800 元。嗯，不对，应该是 16000 元。"],
            ["预算先按 16800 元。", "嗯，", "不对，", "应该是 16000 元。"],
            ["预算先按 16800 元。", "嗯，", "不", "对，", "应该", "是 16000 元。"],
        ]

        for (partitionIndex, parts) in texts.enumerated() {
            let segments = parts.enumerated().map { index, part in
                RecognitionSegment(
                    id: "p\(partitionIndex)-s\(index)",
                    text: part,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
            }
            let text = parts.joined()
            let request = VoicePolishRequest(
                input: VoiceInputEnvelope(
                    providerFinalText: text,
                    segments: segments,
                    durationMs: 1_000,
                    provider: .volcano
                ),
                context: WritingContext(scene: .workChat),
                preferences: UserPolishPreferences(additionalRequirements: ""),
                qualityMode: .automatic
            )
            let facts = ProtectedFactExtractor.extract(from: segments)
            let superseded = VoicePolishValidator.locallySupersededFactIndices(
                request: request,
                sourceFacts: facts
            )
            let supersededValues = Set(superseded.compactMap { facts[$0].canonicalValue })
            XCTAssertEqual(supersededValues, ["16800"], "partition=\(parts)")
        }
    }

    func testParallelModalAmountsAreNotMistakenForCorrections() {
        for source in [
            "基础版价格 2 万元，高级版应该是 3 万元。",
            "基础版价格 2 万元，高级版改成 3 万元。",
            "A 方案安排 2 人，B 方案应该是 3 人。",
        ] {
            let request = makeRequest(source, scene: .workChat)
            let facts = ProtectedFactExtractor.extract(from: request.input.segments)
            XCTAssertTrue(
                VoicePolishValidator.locallySupersededFactIndices(
                    request: request,
                    sourceFacts: facts
                ).isEmpty,
                source
            )
        }

        let correction = makeRequest(
            "预算先按 2 万元，不对，应该是 3 万元。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: correction.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: correction,
            sourceFacts: facts
        )
        XCTAssertEqual(Set(superseded.compactMap { facts[$0].canonicalValue }), ["20000"])
    }

    func testFormatInstructionDoesNotBindLaterIncompleteQuantityAsNewValue() {
        let request = makeRequest(
            "请把这 3 个问题改成表格，明天先交 1 版。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)
    }

    func testCorrectionCanSpanOldFactResetPhraseAndFinalFactAcrossThreeSegments() {
        let segments = [
            RecognitionSegment(id: "s1", text: "预算先按 16800 元准备。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s2", text: "不对，最终预算", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s3", text: "改成 16000 元，周五发方案。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
        ]
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: segments.map(\.text).joined(),
                segments: segments,
                durationMs: 3_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let facts = ProtectedFactExtractor.extract(from: segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16800" })
        let finalIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16000" })

        XCTAssertTrue(superseded.contains(oldIndex))
        XCTAssertFalse(superseded.contains(finalIndex))
    }

    func testCorrectionCanSpanFourProviderSegmentsWithoutChangingMeaning() {
        let segments = [
            RecognitionSegment(id: "s1", text: "预算先按 16800 元。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s2", text: "不对，", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s3", text: "最终预算", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
            RecognitionSegment(id: "s4", text: "改成 16000 元。", startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true),
        ]
        let text = segments.map(\.text).joined()
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: segments,
                durationMs: 3_000,
                provider: .volcano
            ),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic
        )
        let facts = ProtectedFactExtractor.extract(from: segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16800" })
        let finalIndex = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "16000" })

        XCTAssertEqual(superseded, [oldIndex])
        XCTAssertFalse(superseded.contains(finalIndex))
    }

    func testTwoConsecutiveCorrectionsKeepOnlyTheLastValue() {
        let request = makeRequest(
            "先安排 3 人，不对，应该是 4 人，不对，应该是 5 人。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let three = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "3" })
        let four = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "4" })
        let five = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "5" })

        XCTAssertTrue(superseded.contains(three))
        XCTAssertTrue(superseded.contains(four))
        XCTAssertFalse(superseded.contains(five))
    }

    func testMultipleCorrectionWordsDescribeOneDateReplacement() {
        let request = makeRequest(
            "课程使用 AI。录制原计划在九月三日完成，这个时间不现实，不对，最终改成九月十日完成；九月十二日复核。不要压成十几行摘要。",
            scene: .document
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        let oldDate = try! XCTUnwrap(facts.firstIndex { $0.canonicalValue == "09-03" })

        XCTAssertEqual(superseded, [oldDate])
    }

    func testWorkChatCorrectionNoticePreservesOldAndNewFacts() {
        let request = makeRequest(
            "更正一下，上一条把日期写成 8 月 20 日有误，正确日期是 8 月 28 日，请大家以这条为准。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)

        XCTAssertTrue(VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        ).isEmpty)
        let validation = VoicePolishValidator.validateFast(
            output: "更正说明：上一条中的 8 月 20 日有误，正确日期为 8 月 28 日，请大家以此为准。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.hasHardFailure, "\(validation.codes)")
    }

    func testWorkChatSelfCorrectionIsNotMistakenForPublicNotice() {
        let request = makeRequest(
            "说明一下，我刚才说错了，预算先说 2 万元，不对，应该是 3 万元。",
            scene: .workChat
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: facts
        )
        XCTAssertEqual(Set(superseded.compactMap { facts[$0].canonicalValue }), ["20000"])

        let validation = VoicePolishValidator.validateFast(
            output: "预算为 3 万元。",
            request: request,
            sourceFacts: facts
        )
        XCTAssertFalse(validation.hasHardFailure, "\(validation.codes)")
    }

    func testVoicePolishDedicatedModelOverrideIsTrimmedAndOptional() {
        let suite = "VoicePolishModelOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        VoicePolishSettings.setModelOverride("  fast-model  ", defaults: defaults)
        XCTAssertEqual(VoicePolishSettings.modelOverride(defaults: defaults), "fast-model")

        VoicePolishSettings.setModelOverride("   ", defaults: defaults)
        XCTAssertNil(VoicePolishSettings.modelOverride(defaults: defaults))
    }

    func testInputEnvelopeAlwaysCoversAuthoritativeFinalTranscript() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["已确认的前半句，"],
            partialText: "尚未确认",
            authoritativeText: "",
            isFinal: true
        )

        let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: "已确认的前半句，最终完整后半句。",
            canonicalText: "已确认的前半句，最终完整后半句。",
            durationMs: 2_000,
            provider: .volcano
        )

        XCTAssertEqual(envelope?.providerFinalText, "已确认的前半句，最终完整后半句。")
        XCTAssertEqual(envelope?.segments.map(\.text), ["已确认的前半句，最终完整后半句。"])
        XCTAssertEqual(envelope?.segments.map(\.id), ["s1"])
    }

    func testInputEnvelopeKeepsRawEvidenceAndUsesCanonicalFallback() {
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: raw,
            canonicalText: canonical,
            durationMs: 1_000,
            provider: .volcano
        )

        XCTAssertEqual(envelope?.providerFinalText, raw)
        XCTAssertEqual(envelope?.rawSegments.map(\.text), [raw])
        XCTAssertEqual(envelope?.canonicalText, canonical)
        XCTAssertEqual(envelope?.segments.map(\.text), [canonical])
        XCTAssertEqual(envelope?.fallbackText, canonical)
    }

    func testCanonicalizationKeepsSegmentIdentityAndRecordsActualTerminologyEdit() throws {
        let rawSegments = ["我正在使用 Type less。", "它很好用。"]
        let raw = rawSegments.joined()
        let canonicalSegments = ["我正在使用 Typeless。", "它很好用。"]
        let canonical = canonicalSegments.joined()
        let transcript = RecognitionTranscript(
            confirmedSegments: rawSegments,
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let envelope = try XCTUnwrap(VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            rawFinalText: raw,
            canonicalText: canonical,
            preferredCanonicalSegmentTexts: canonicalSegments,
            deterministicCorrections: ["Type less": "Typeless"],
            durationMs: 1_000,
            provider: .volcano
        ))

        XCTAssertEqual(envelope.rawSegments.map(\.id), ["s1", "s2"])
        XCTAssertEqual(envelope.segments.map(\.id), ["s1", "s2"])
        XCTAssertEqual(envelope.segments.map(\.text), canonicalSegments)
        XCTAssertEqual(envelope.requiredEntityEdits, [VoiceTerminologyEdit(
            alias: "Type less",
            canonical: "Typeless",
            sourceSegmentIDs: ["s1"]
        )])
    }

    private func route(
        _ text: String,
        requirements: String = "",
        scene: WritingScene = .unknown
    ) -> VoicePolishRoute {
        let request = makeRequest(text, requirements: requirements, scene: scene)
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        return VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: facts
        ).route
    }

    private func makeRequest(
        _ text: String,
        requirements: String = "",
        scene: WritingScene = .unknown
    ) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: [segment(text)],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: scene),
            preferences: UserPolishPreferences(additionalRequirements: requirements),
            qualityMode: .balanced
        )
    }

    private func executedRoute(
        _ baseRequest: VoicePolishRequest,
        quality: VoicePolishQualityMode
    ) -> VoicePolishRoute {
        let request = VoicePolishRequest(
            input: baseRequest.input,
            context: baseRequest.context,
            preferences: baseRequest.preferences,
            qualityMode: quality
        )
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        let decision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: facts
        )
        return VoicePolishComplexityRouter.executedRoute(for: decision, request: request)
    }

    private func segment(_ text: String) -> RecognitionSegment {
        RecognitionSegment(
            id: "s1",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8)!
    }
}

private struct SimplePayload: Codable, Equatable {
    let message: String
}
