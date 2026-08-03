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

    func testQualityModesApplyDeterministicExecutionPolicy() {
        let simple = makeRequest("今天下午把方案发出去。")
        let enumeration = makeRequest("第一，写方案。第二，补测试。")
        let structured = makeRequest("顺便说一下，预算也要再确认。")
        let deep = makeRequest("先用红色，不对，我改一下，应该是蓝色。")

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

    func testFactExtractorDeduplicatesSameSemanticFactWithinOneSegment() {
        let facts = ProtectedFactExtractor.extract(from: [
            segment("预算 49,800 元，最后仍按 4.98 万执行。"),
        ])

        XCTAssertEqual(
            facts.filter { $0.kind == .amount && $0.canonicalValue == "49800" }.count,
            1
        )
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

        XCTAssertEqual(VoicePolishSettings.qualityMode(defaults: defaults), .balanced)
        XCTAssertEqual(VoicePolishSettings.contextLevel(defaults: defaults), .metadataOnly)
        XCTAssertFalse(VoicePolishSettings.personalizationEnabled(defaults: defaults))
        XCTAssertTrue(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertEqual(VoicePolishSettings.correctionLimit(defaults: defaults), 200)
        XCTAssertNil(VoicePolishSettings.modelOverride(defaults: defaults))
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
