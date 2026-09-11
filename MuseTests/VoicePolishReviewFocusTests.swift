import XCTest
@testable import Muse

final class VoicePolishReviewFocusTests: XCTestCase {
    func testExistingChangeTextAndOrderRemainCompatible() {
        let cases: [(String, String, [VoicePolishTextChange])] = [
            ("", "", []),
            ("完全相同", "完全相同", []),
            ("原文", "", [.init(removed: "原文", inserted: "")]),
            ("", "新增", [.init(removed: "", inserted: "新增")]),
            ("甲旧乙丙末", "甲新乙添丙尾", [
                .init(removed: "旧", inserted: "新"),
                .init(removed: "", inserted: "添"),
                .init(removed: "末", inserted: "尾")
            ])
        ]
        for (source, draft, expected) in cases {
            XCTAssertEqual(VoicePolishTextChange.between(source, draft), expected)
            XCTAssertEqual(VoicePolishTextChange.comparisonEvidence(source, draft).changes, expected)
        }
    }

    func testReasonDeletionIsVisibleAfterManyPunctuationChanges() throws {
        let anchors = (0..<40).map { String(UnicodeScalar(0x4E10 + $0)!) }
        let sourcePrefix = anchors.joined(separator: "，")
        let draftPrefix = anchors.joined(separator: "。")
        let reason = "因为仓库停电无法完成最后一轮检查"
        let source = sourcePrefix + "通知：" + reason + "。材料暂存原处。"
        let draft = draftPrefix + "通知：。材料暂存原处。"
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        XCTAssertGreaterThan(evidence.changes.count, 16)
        XCTAssertEqual(evidence.contentChangeCount, 1)
        let focus = try XCTUnwrap(evidence.reviewFocus.first)
        XCTAssertEqual(evidence.changes[focus.changeIndex], .init(removed: reason, inserted: ""))
        XCTAssertTrue(focus.sourceContext.contains(reason))
        XCTAssertEqual(focus.draftStart, focus.draftEnd)
        assertRangesMatch(evidence, source: source, draft: draft)
    }

    func testPureDeletionKeepsActualDraftInsertionPointAndFullContext() throws {
        let source = "前缀需要保留的原因后缀"
        let draft = "前缀后缀"
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        let focus = try XCTUnwrap(evidence.reviewFocus.first)
        XCTAssertEqual(focus.sourceStart, 2)
        XCTAssertEqual(focus.sourceEnd, source.count - 2)
        XCTAssertEqual(focus.draftStart, 2)
        XCTAssertEqual(focus.draftEnd, 2)
        XCTAssertEqual(focus.sourceContext, source)
        XCTAssertEqual(focus.draftContext, draft)
        assertRangesMatch(evidence, source: source, draft: draft)
    }

    func testContextsContainWholeBlockAndExactlyTwentyCharactersOnEachSide() throws {
        let prefix = String(repeating: "甲", count: 25)
        let suffix = String(repeating: "丙", count: 25)
        let removed = String(repeating: "旧", count: 60)
        let inserted = "新"
        let source = prefix + removed + suffix
        let draft = prefix + inserted + suffix
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        let focus = try XCTUnwrap(evidence.reviewFocus.first)
        XCTAssertEqual(focus.sourceStart, 25)
        XCTAssertEqual(focus.sourceEnd, 85)
        XCTAssertEqual(focus.draftStart, 25)
        XCTAssertEqual(focus.draftEnd, 26)
        XCTAssertEqual(focus.sourceContext, String(repeating: "甲", count: 20) + removed + String(repeating: "丙", count: 20))
        XCTAssertEqual(focus.draftContext, String(repeating: "甲", count: 20) + inserted + String(repeating: "丙", count: 20))
    }

    func testCharacterOffsetsKeepCombiningLettersEmojiAndCRLFTogether() throws {
        let source = "甲e\u{301}👩🏽‍💻\r\n乙🇨🇳丙"
        let draft = "甲e\u{301}\r\n乙🙂丙"
        XCTAssertEqual(source.count, 7)
        XCTAssertEqual(draft.count, 6)
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        XCTAssertEqual(evidence.changes, [
            .init(removed: "👩🏽‍💻", inserted: ""),
            .init(removed: "🇨🇳", inserted: "🙂")
        ])
        let deletion = try XCTUnwrap(evidence.reviewFocus.first { $0.changeIndex == 0 })
        XCTAssertEqual(deletion.sourceStart, 2)
        XCTAssertEqual(deletion.sourceEnd, 3)
        XCTAssertEqual(deletion.draftStart, 2)
        XCTAssertEqual(deletion.draftEnd, 2)
        let replacement = try XCTUnwrap(evidence.reviewFocus.first { $0.changeIndex == 1 })
        XCTAssertEqual(replacement.sourceStart, 5)
        XCTAssertEqual(replacement.sourceEnd, 6)
        XCTAssertEqual(replacement.draftStart, 4)
        XCTAssertEqual(replacement.draftEnd, 5)
        assertRangesMatch(evidence, source: source, draft: draft)

        let accent = VoicePolishTextChange.comparisonEvidence("甲e\u{301}乙", "甲ö乙")
        XCTAssertEqual(accent.reviewFocus.first?.sourceStart, 1)
        XCTAssertEqual(accent.reviewFocus.first?.sourceEnd, 2)
        XCTAssertEqual(accent.reviewFocus.first?.draftEnd, 2)
        assertRangesMatch(accent, source: "甲e\u{301}乙", draft: "甲ö乙")
    }

    func testRepeatedTextKeepsBothDistinctPositions() {
        let source = "甲重复乙重复丙"
        let draft = "甲乙丙"
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        XCTAssertEqual(evidence.changes, [.init(removed: "重复", inserted: ""), .init(removed: "重复", inserted: "")])
        XCTAssertEqual(evidence.reviewFocus.map(\.changeIndex), [0, 1])
        XCTAssertEqual(evidence.reviewFocus.map(\.sourceStart), [1, 4])
        XCTAssertEqual(evidence.reviewFocus.map(\.sourceEnd), [3, 6])
        XCTAssertEqual(evidence.reviewFocus.map(\.draftStart), [1, 2])
        XCTAssertEqual(evidence.reviewFocus.map(\.draftEnd), [1, 2])
        assertRangesMatch(evidence, source: source, draft: draft)
    }

    func testPriorityUsesDeletionThenSizeThenOriginalChangeIndex() {
        let source = "甲删乙丙去除丁旧戊"
        let draft = "甲乙大量新增文字丙丁新戊"
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        XCTAssertEqual(evidence.changes, [
            .init(removed: "删", inserted: ""), .init(removed: "", inserted: "大量新增文字"),
            .init(removed: "去除", inserted: ""), .init(removed: "旧", inserted: "新")
        ])
        XCTAssertEqual(evidence.reviewFocus.map(\.changeIndex), [2, 3, 0, 1])
        XCTAssertEqual(evidence.contentChangeCount, 4)
        assertRangesMatch(evidence, source: source, draft: draft)
    }

    func testOnlyExplicitLayoutCharactersStayOutsideFocus() {
        let source = "甲，。！？；：、 \t\r\n乙"
        let evidence = VoicePolishTextChange.comparisonEvidence(source, "甲乙")
        XCTAssertFalse(evidence.changes.isEmpty)
        XCTAssertTrue(evidence.reviewFocus.isEmpty)
        XCTAssertEqual(evidence.contentChangeCount, 0)
        let newline = VoicePolishTextChange.comparisonEvidence("甲\r\n乙", "甲\n乙")
        XCTAssertFalse(newline.changes.isEmpty)
        XCTAssertEqual(newline.contentChangeCount, 0)
    }

    func testTechnicalSymbolsPathsOperatorsAndEmojiRemainContentChanges() {
        for symbol in ["/", "\\", ".", ":", "_", "-", "+", "=", "<", ">", "*", "&", "|", "!", "?", "@", "#", "%", "`", "👩🏽‍💻"] {
            let source = "甲" + symbol + "乙"
            let evidence = VoicePolishTextChange.comparisonEvidence(source, "甲乙")
            XCTAssertEqual(evidence.contentChangeCount, 1, symbol)
            XCTAssertEqual(evidence.reviewFocus.count, 1, symbol)
            XCTAssertEqual(evidence.changes, [.init(removed: symbol, inserted: "")])
            assertRangesMatch(evidence, source: source, draft: "甲乙")
        }
        for (source, draft) in [("读取 .env 文件", "读取 env 文件"), ("路径 a/b", "路径 ab"), ("x!=y", "x=y")] {
            XCTAssertGreaterThan(VoicePolishTextChange.comparisonEvidence(source, draft).contentChangeCount, 0)
        }
    }

    func testFocusCapDoesNotDropCompleteChangesOrTotalCount() {
        let anchors = (0..<21).map { String(UnicodeScalar(0x5100 + $0)!) }
        let source = anchors.joined(separator: "删")
        let draft = anchors.joined()
        let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
        XCTAssertEqual(evidence.changes.count, 20)
        XCTAssertEqual(evidence.contentChangeCount, 20)
        XCTAssertEqual(evidence.reviewFocus.map(\.changeIndex), Array(0..<16))
        XCTAssertEqual(evidence.changes, Array(repeating: .init(removed: "删", inserted: ""), count: 20))
        assertRangesMatch(evidence, source: source, draft: draft)
    }

    func testEmptyAndUnchangedSourcesHaveNoInventedFocus() throws {
        for (source, draft) in [("", ""), ("相同🙂", "相同🙂")] {
            let evidence = VoicePolishTextChange.comparisonEvidence(source, draft)
            XCTAssertEqual(evidence.changes, [])
            XCTAssertEqual(evidence.reviewFocus, [])
            XCTAssertEqual(evidence.contentChangeCount, 0)
        }
        let insertion = try XCTUnwrap(VoicePolishTextChange.comparisonEvidence("", "新增").reviewFocus.first)
        XCTAssertEqual(insertion.sourceStart, 0)
        XCTAssertEqual(insertion.sourceEnd, 0)
        XCTAssertEqual(insertion.sourceContext, "")
        XCTAssertEqual(insertion.draftContext, "新增")
        let deletion = try XCTUnwrap(VoicePolishTextChange.comparisonEvidence("删除", "").reviewFocus.first)
        XCTAssertEqual(deletion.draftStart, 0)
        XCTAssertEqual(deletion.draftEnd, 0)
        XCTAssertEqual(deletion.draftContext, "")
    }

    func testFocusEncodesExplicitOffsetsAndUnmodifiedContexts() throws {
        let focus = try XCTUnwrap(VoicePolishTextChange.comparisonEvidence("甲🙂乙", "甲乙").reviewFocus.first)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(focus)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["change_index", "source_start", "source_end", "draft_start", "draft_end", "source_context", "draft_context"])
        XCTAssertEqual(object["source_context"] as? String, "甲🙂乙")
        XCTAssertEqual(object["draft_context"] as? String, "甲乙")
        XCTAssertEqual(object["source_start"] as? Int, 1)
        XCTAssertEqual(object["source_end"] as? Int, 2)
        XCTAssertEqual(object["draft_start"] as? Int, 1)
        XCTAssertEqual(object["draft_end"] as? Int, 1)
    }

    private func assertRangesMatch(_ evidence: VoicePolishTextChange.ComparisonEvidence,
                                   source: String, draft: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let old = Array(source)
        let new = Array(draft)
        for focus in evidence.reviewFocus {
            XCTAssertTrue(0 <= focus.sourceStart && focus.sourceStart <= focus.sourceEnd && focus.sourceEnd <= old.count,
                          file: file, line: line)
            XCTAssertTrue(0 <= focus.draftStart && focus.draftStart <= focus.draftEnd && focus.draftEnd <= new.count,
                          file: file, line: line)
            guard 0 <= focus.sourceStart, focus.sourceStart <= focus.sourceEnd, focus.sourceEnd <= old.count,
                  0 <= focus.draftStart, focus.draftStart <= focus.draftEnd, focus.draftEnd <= new.count,
                  evidence.changes.indices.contains(focus.changeIndex) else { continue }
            let change = evidence.changes[focus.changeIndex]
            XCTAssertEqual(String(old[focus.sourceStart..<focus.sourceEnd]), change.removed, file: file, line: line)
            XCTAssertEqual(String(new[focus.draftStart..<focus.draftEnd]), change.inserted, file: file, line: line)
            XCTAssertEqual(String(old[max(0, focus.sourceStart - 20)..<min(old.count, focus.sourceEnd + 20)]), focus.sourceContext,
                           file: file, line: line)
            XCTAssertEqual(String(new[max(0, focus.draftStart - 20)..<min(new.count, focus.draftEnd + 20)]), focus.draftContext,
                           file: file, line: line)
        }
    }
}
