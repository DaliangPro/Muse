import XCTest
@testable import Muse

final class VoicePolishEditingReviewTests: XCTestCase {
    func testDeclaredEditorInstructionCannotSurviveByChangingPunctuation() throws {
        let source = "帮我回他一下，我会晚点到。"
        let review = try VoicePolishEditingReview.decode(
            #"{"source_roles":[{"quote":"帮我回他一下，","role":"current_editor","target_evidence":"帮我回他一下"}],"edits":[]}"#,
            source: source
        )
        XCTAssertTrue(review.containsUnappliedEditorInstruction(in: "帮我回他一下：我会晚点到。"))
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: "我会晚点到。"))
    }

    func testRecipientAndUncertainRolesDoNotAuthorizeDeletion() throws {
        let source = "同事接下来的任务是替我回客户。先别承诺时间，尚未确定。"
        let review = try VoicePolishEditingReview.decode(
            #"{"source_roles":[{"quote":"替我回客户","role":"recipient_content","target_evidence":"同事接下来的任务"},{"quote":"先别承诺时间","role":"uncertain","target_evidence":"尚未确定"}],"edits":[]}"#,
            source: source
        )
        XCTAssertTrue(review.edits.isEmpty)
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: source))
    }

    func testReviewRejectsMissingRolesUnknownRolesAndInventedEvidence() {
        for raw in [
            #"{"edits":[]}"#,
            #"{"source_roles":null,"edits":[]}"#,
            #"{"source_roles":[],"edits":[],"approved":true}"#,
            #"{"source_roles":[{"quote":"请整理","role":"approved","target_evidence":"请整理"}],"edits":[]}"#,
            #"{"source_roles":[{"quote":"请整理","role":"current_editor","target_evidence":"老板要求"}],"edits":[]}"#,
            #"{"source_roles":[{"quote":"请删除","role":"current_editor","target_evidence":"请整理"}],"edits":[]}"#,
            #"{"source_roles":[{"quote":"。","role":"current_editor","target_evidence":"请整理"}],"edits":[]}"#,
            "{invalid"
        ] {
            XCTAssertThrowsError(try VoicePolishEditingReview.decode(raw, source: "请整理这段话。"), raw)
        }
    }

    func testRepeatedRoleQuotesCannotChooseAnArbitraryOccurrence() {
        let raw = #"{"source_roles":[{"quote":"不要开始","role":"current_editor","target_evidence":"请整理"}],"edits":[]}"#
        XCTAssertThrowsError(try VoicePolishEditingReview.decode(raw, source: "请整理。不要开始。告诉他不要开始。"))
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
