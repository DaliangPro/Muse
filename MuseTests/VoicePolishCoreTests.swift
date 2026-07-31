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
        XCTAssertEqual(route("第一，写方案。第二，补测试。"), .structured)
        XCTAssertEqual(route("I mean, ship it tomorrow."), .structured)
        XCTAssertEqual(route("Scratch that. I mean, ship it Friday."), .deep)
    }

    func testRouterUsesCharacterAndWordThresholds() {
        XCTAssertEqual(route(String(repeating: "中", count: 120)), .fast)
        XCTAssertEqual(route(String(repeating: "中", count: 121)), .structured)
        XCTAssertEqual(route(String(repeating: "中", count: 501)), .deep)
        XCTAssertEqual(route(Array(repeating: "word", count: 80).joined(separator: " ")), .fast)
        XCTAssertEqual(route(Array(repeating: "word", count: 81).joined(separator: " ")), .structured)
        XCTAssertEqual(route(Array(repeating: "word", count: 301).joined(separator: " ")), .deep)
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

    func testInputEnvelopeAlwaysCoversAuthoritativeFinalTranscript() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["已确认的前半句，"],
            partialText: "尚未确认",
            authoritativeText: "",
            isFinal: true
        )

        let envelope = VoiceInputEnvelope.fromFinalTranscript(
            transcript,
            finalText: "已确认的前半句，最终完整后半句。",
            durationMs: 2_000,
            provider: .volcano
        )

        XCTAssertEqual(envelope?.providerFinalText, "已确认的前半句，最终完整后半句。")
        XCTAssertEqual(envelope?.segments.map(\.text), ["已确认的前半句，最终完整后半句。"])
        XCTAssertEqual(envelope?.segments.map(\.id), ["s1"])
    }

    private func route(_ text: String, scene: WritingScene = .unknown) -> VoicePolishRoute {
        let request = makeRequest(text, scene: scene)
        let facts = ProtectedFactExtractor.extract(from: request.input.segments)
        return VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: facts
        ).route
    }

    private func makeRequest(_ text: String, scene: WritingScene = .unknown) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: [segment(text)],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: scene),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
        )
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
