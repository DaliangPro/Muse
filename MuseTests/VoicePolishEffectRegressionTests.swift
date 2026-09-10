import XCTest
@testable import Muse

/// 2026-09-10 后台真实跑测发现的正反例。这里复现确定性校验问题；
/// 最终成稿质量仍须用真实 Provider 与独立评审验证。
final class VoicePolishEffectRegressionTests: XCTestCase {
    func test连续改口必须避开旧Fast对半点时间的误拦() {
        assertValid(
            source: "会议改到周三上午十点不对周四上午十点哎十点半才对地点还是三号会议室",
            output: "会议改到周四上午十点半，地点还是三号会议室。"
        )
    }

    func test连续改口不能放行已作废的整点时间() {
        assertInvalid(
            source: "会议改到周三上午十点不对周四上午十点哎十点半才对地点还是三号会议室",
            output: "会议改到周四上午十点，地点还是三号会议室。"
        )
    }

    func test更正通知必须避开旧Fast对编辑数量的误拦() {
        assertValid(
            source: "发一条更正通知昨天公告里写的报名费是二百六十元这个写错了正确的是二百一十元已经按二百六十元交费的会退五十元",
            output: "更正通知：昨天公告里的报名费写错了，原写为二百六十元，正确的是二百一十元。已经按二百六十元交费的，会退五十元。"
        )
    }

    func test更正通知不能改错退款金额() {
        assertInvalid(
            source: "发一条更正通知昨天公告里写的报名费是二百六十元这个写错了正确的是二百一十元已经按二百六十元交费的会退五十元",
            output: "更正通知：昨天公告报名费误写为二百六十元，正确价格是二百一十元。已按二百六十元交费的，会退六十元。"
        )
    }

    func test必要条件必须避开旧Fast的字面否定判断() {
        assertValid(
            source: "只有测试通过并且小周签字以后才能发给客户任何一个没完成都先别发内部预览可以继续",
            output: "只有测试通过并且小周签字以后，才能发给客户。任何一项没完成都先别发，内部预览可以继续。"
        )
    }

    func test已确认上下文纠名必须避开旧Fast的字面否定判断() {
        let source = "灵检这个项目的登录页先别上线等我把按钮文案看完"
        let context = WritingContext(
            scene: .workChat,
            level: .nearbyText,
            safety: .safe,
            textBeforeCursor: "当前讨论的项目正式名称是“灵简”，登录页属于灵简项目。另一个项目预算为47万元。"
        )
        assertValid(
            source: source,
            output: "灵简这个项目的登录页先别上线，等我把按钮文案看完。",
            context: context
        )
    }

    func test上下文无关预算不能加入正文() {
        let context = WritingContext(
            scene: .workChat,
            level: .nearbyText,
            safety: .safe,
            textBeforeCursor: "当前讨论的项目正式名称是“灵简”，另一个项目预算为47万元。"
        )
        assertInvalid(
            source: "灵检这个项目的登录页先别上线等我把按钮文案看完",
            output: "灵简这个项目的登录页先别上线，等我把按钮文案看完。预算为47万元。",
            context: context
        )
    }

    private func assertValid(
        source: String,
        output: String,
        context: WritingContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = validate(source: source, output: output, context: context)
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(source: source, context: context)), result.1, file: file, line: line)
    }

    private func assertInvalid(
        source: String,
        output: String,
        context: WritingContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = validate(source: source, output: output, context: context)
        XCTAssertTrue(result.0.hasHardFailure, result.1, file: file, line: line)
    }

    private func validate(
        source: String,
        output: String,
        context: WritingContext?
    ) -> (VoicePolishValidationResult, String) {
        let request = makeRequest(source: source, context: context)
        let envelope = request.input
        let entities = request.resolvedEntities
        let facts = ProtectedFactExtractor.extract(from: envelope.segments) + entities.map {
            SourceFactCandidate(
                sourceText: $0.surfaceText,
                canonicalValue: $0.canonical,
                kind: .lexiconEntity,
                sourceSegmentIDs: $0.sourceSegmentIDs
            )
        }
        let result = VoicePolishValidator.validateFast(
            output: output, request: request, sourceFacts: facts
        )
        let description = facts.map {
            "\($0.kind.rawValue):\($0.sourceText)=\($0.canonicalValue ?? "nil")"
        }.joined(separator: "; ")
        return (result, "codes=\(result.codes); sourceFacts=\(description)")
    }
    private func makeRequest(source: String, context: WritingContext?) -> VoicePolishRequest {
        let envelope = VoiceInputEnvelope(
            providerFinalText: source,
            segments: [RecognitionSegment(
                id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                confidence: nil, isFinal: true
            )],
            durationMs: 1_000,
            provider: .volcano
        )
        let writingContext = context ?? WritingContext(scene: .workChat)
        let entities = EntityResolver.resolve(
            segments: envelope.segments,
            lexicon: .empty, snippets: [], hotwords: [], context: writingContext
        )
        return VoicePolishRequest(
            input: envelope,
            context: writingContext,
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic,
            resolvedEntities: entities
        )
    }

}
