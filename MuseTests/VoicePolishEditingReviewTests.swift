import XCTest
@testable import Muse

final class VoicePolishEditingReviewTests: XCTestCase {
    func testDeclaredEditorInstructionCannotSurviveByChangingPunctuation() throws {
        let source = "帮我回他一下，我会晚点到。"
        let review = try VoicePolishEditingReview.decode(
            #"{"delivery":"direct_reply","editor_spans":["帮我回他一下，"],"edits":[]}"#,
            source: source
        )
        XCTAssertTrue(review.containsUnappliedEditorInstruction(in: "帮我回他一下：我会晚点到。"))
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: "我会晚点到。"))
    }

    func testDeliveryDoesNotAuthorizeDeletionOrRequireCopyingRecipientTasks() throws {
        let source = "同事接下来的任务是替我回客户。先别承诺时间，尚未确定。"
        let review = try VoicePolishEditingReview.decode(
            #"{"delivery":"delegated_task","editor_spans":[],"edits":[]}"#,
            source: source
        )
        XCTAssertTrue(review.edits.isEmpty)
        XCTAssertEqual(review.delivery, .delegatedTask)
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: source))
    }

    func testReviewRejectsMissingFieldsUnknownDeliveryAndInventedQuotes() {
        for raw in [
            #"{"edits":[]}"#,
            #"{"source_roles":null,"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"approved":true}"#,
            #"{"delivery":"assistant","editor_spans":[],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["用户要求输入法整理这段话"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["请删除"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["。"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["请整理","请整理"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":null,"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":[{"quote":"请整理"}],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":[],"edits":null}"#,
            "{invalid"
        ] {
            XCTAssertThrowsError(try VoicePolishEditingReview.decode(raw, source: "请整理这段话。"), raw)
        }
    }

    func testRepeatedEditorQuotesCannotChooseAnArbitraryOccurrence() {
        let raw = #"{"delivery":"other_or_uncertain","editor_spans":["不要开始"],"edits":[]}"#
        XCTAssertThrowsError(try VoicePolishEditingReview.decode(raw, source: "请整理。不要开始。告诉他不要开始。"))
        XCTAssertThrowsError(try VoicePolishEditingReview.decode(
            #"{"delivery":"other_or_uncertain","editor_spans":["哈哈"],"edits":[]}"#,
            source: "哈哈哈"))
    }

    func testRepeatedRecipientTextDoesNotNeedToBecomeEditorMetadata() throws {
        let source = "请去掉口误。甲组逐项核对并保留原因。乙组逐项核对并保留原因。"
        let review = try VoicePolishEditingReview.decode(
            #"{"delivery":"delegated_task","editor_spans":["请去掉口误。"],"edits":[]}"#,
            source: source)
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: "甲组逐项核对并保留原因。乙组逐项核对并保留原因。"))
    }

    func testCurrentPromptInstructionDoesNotIncludeItsBudgetFact() throws {
        let source = "帮我写成任务，只整理别真的执行。预算两百，先等资料齐再比较。"
        let review = try VoicePolishEditingReview.decode(
            #"{"delivery":"ai_prompt","editor_spans":["帮我写成任务，只整理别真的执行。"],"edits":[]}"#,
            source: source)
        XCTAssertEqual(review.delivery, .aiPrompt)
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: "预算两百，先等资料齐再比较。"))
        XCTAssertTrue(review.edits.isEmpty)
    }

    func testRiskRoutingDoesNotDependOnGeneratedChanges() {
        for source in ["帮我回他一下我晚点到", "给客户回一条，我们还在检查。", "复查改由阿宁，阿文要出差。",
                       "先别执行，只整理任务。", "Actually, make that Tuesday."] {
            XCTAssertTrue(VoicePolishEditingReview.hasSourceReviewRisk(source), source)
        }
        for source in ["我今天晚点到。", "对对对，我明白了。", "先检查，再发送。"] {
            XCTAssertFalse(VoicePolishEditingReview.hasSourceReviewRisk(source), source)
        }
    }
}
