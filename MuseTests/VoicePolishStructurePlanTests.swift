import XCTest
@testable import Muse

final class VoicePolishStructurePlanTests: XCTestCase {
    typealias Plan = VoicePolishStructurePlan

    func testCompleteSegmentsPreserveReasonAndConditionalActionAsOneSentence() throws {
        let source = "先准备材料。因为仓库停电，如果今晚不能恢复，就明早再上传。最后通知对方。"
        let segments = try Plan.segments(in: source)
        XCTAssertEqual(segments, [
            .init(id: "c1", text: "先准备材料。"),
            .init(id: "c2", text: "因为仓库停电，如果今晚不能恢复，就明早再上传。"),
            .init(id: "c3", text: "最后通知对方。")
        ])
        assertBytesPreserved(segments, source: source)
    }

    func testUnpunctuatedDraftAndBareNewlinesStayWhole() throws {
        for source in ["如果文件没到，就先等，到了再核对", "第一行\n\n第二行\r\n条件齐了再做", "\t保留缩进\r\n    然后继续"] {
            let segments = try Plan.segments(in: source)
            XCTAssertEqual(segments, [.init(id: "c1", text: source)])
            assertBytesPreserved(segments, source: source)
        }
    }

    func testQuotedAndBracketedSentenceEndsDoNotSplitTheirContents() throws {
        for source in [
            "他说“如果失败。先别重试！”然后再核对。下一步另说。",
            "说明（条件未齐。暂不执行）后再提交。下一句。",
            "先看【附注：条件未齐。需要等待】再提交。下一句。",
            #"他说 "路径 \"a.b\"。继续" 后再处理。下一句。"#
        ] {
            let segments = try Plan.segments(in: source)
            XCTAssertEqual(segments.count, 2, source)
            assertBytesPreserved(segments, source: source)
        }
        for source in ["先核对（条件未齐。暂不执行。", "他说“不要运行。先等着。"] {
            XCTAssertEqual(try Plan.segments(in: source), [.init(id: "c1", text: source)])
        }
    }

    func testInlineFencedAndIndentedCodeRemainIntact() throws {
        let sources = [
            "使用 `a.b(); // stop. Still code!` 再检查。",
            "```swift\r\nlet message = \"甲。乙！\"\r\n// Keep. Still same block!\r\n```\r\n最后核对。",
            "~~~text\nA. B!\n~~~\n后续处理。",
            "    // Keep. Do not split!\r\n    print(\"甲。乙\")\r\n检查结束。",
            "使用 ``包含 ` 和句号。的代码`` 再核对。"
        ]
        for source in sources {
            let segments = try Plan.segments(in: source)
            XCTAssertEqual(segments, [.init(id: "c1", text: source)], source)
            assertBytesPreserved(segments, source: source)
        }
    }

    func testEnglishSentenceEndsPreserveLeadingSpacesAndCommonAbbreviations() throws {
        XCTAssertEqual(try Plan.segments(in: "Ready. Check the package! Continue?"), [
            .init(id: "c1", text: "Ready."), .init(id: "c2", text: " Check the package!"),
            .init(id: "c3", text: " Continue?")
        ])
        XCTAssertEqual(try Plan.segments(in: "Dr. Lee reviewed the file. Done."), [
            .init(id: "c1", text: "Dr. Lee reviewed the file."), .init(id: "c2", text: " Done.")
        ])
    }

    func testPathsDecimalsDomainsAndOperatorsAreNotSentenceBoundaries() throws {
        for source in [
            "版本 v1.2.3 路径 src/app.swift 和 https://example.com/a.b 数值 3.14。",
            "Open src/file.txt and read v1.2.3. Next step stays here.",
            "if (x != 3.14) { call(\"a.b\"); } 然后继续。",
            "a?b:c x!=y 路径 C:/src/app.swift。"
        ] {
            let segments = try Plan.segments(in: source)
            XCTAssertEqual(segments, [.init(id: "c1", text: source)], source)
            assertBytesPreserved(segments, source: source)
        }
    }

    func testEmojiCombiningLettersCRLFAndTrailingWhitespaceStayByteExact() throws {
        let source = "👩🏽‍💻完成 e\u{301}。 \r\n🇨🇳下一步。\t"
        let segments = try Plan.segments(in: source)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1].text, " \r\n🇨🇳下一步。\t")
        assertBytesPreserved(segments, source: source)
        let blocks = [Plan.Block(style: .paragraph, segmentIDs: segments.map(\.id))]
        XCTAssertEqual(Array(try Plan.render(blocks, segments: segments).utf8), Array(source.utf8))
    }

    func testLayoutReordersAndGroupsOnlyKnownOriginalFragments() throws {
        let segments = try Plan.segments(in: "甲项。乙项原因不能省略。丙项。丁项。")
        let layout: [[String: Any]] = [
            ["style": "paragraph", "segment_ids": ["c2", "c3"]],
            ["style": "numbered", "segment_ids": ["c1"]],
            ["style": "numbered", "segment_ids": ["c4"]]
        ]
        let blocks = try Plan.decodeLayout(from: layout, segments: segments)
        XCTAssertEqual(try Plan.render(blocks, segments: segments), "乙项原因不能省略。丙项。\n\n1. 甲项。\n\n2. 丁项。")
    }

    func testRenderingKeepsCodeIndentationAndResetsNumberingOnlyBetweenLists() throws {
        let segments = [
            Plan.Segment(id: "c1", text: "  第一段。\r\n"),
            Plan.Segment(id: "c2", text: "    code();\r\n\tkeep();"),
            Plan.Segment(id: "c3", text: "第三段。"),
            Plan.Segment(id: "c4", text: "第四段。")
        ]
        let blocks = [Plan.Block(style: .numbered, segmentIDs: ["c1"]),
                      Plan.Block(style: .paragraph, segmentIDs: ["c2"]),
                      Plan.Block(style: .bullet, segmentIDs: ["c3"]),
                      Plan.Block(style: .numbered, segmentIDs: ["c4"])]
        XCTAssertEqual(try Plan.render(blocks, segments: segments),
                       "  1. 第一段。\r\n\n    code();\r\n\tkeep();\n\n- 第三段。\n\n1. 第四段。")
    }

    func testMarkerFreeViewOmitsOnlyProgramPrefixesAndKeepsOriginalNumbering() throws {
        let segments = [Plan.Segment(id: "c1", text: "1. 原始编号。"),
                        Plan.Segment(id: "c2", text: "- 原始横线。\r\n  保留空白")]
        let blocks = [Plan.Block(style: .numbered, segmentIDs: ["c1"]),
                      Plan.Block(style: .bullet, segmentIDs: ["c2"])]
        XCTAssertEqual(try Plan.render(blocks, segments: segments),
                       "1. 1. 原始编号。\n\n- - 原始横线。\r\n  保留空白")
        XCTAssertEqual(try Plan.render(blocks, segments: segments, includesMarkers: false),
                       "1. 原始编号。\n\n- 原始横线。\r\n  保留空白")
        XCTAssertThrowsError(try Plan.render([.init(style: .paragraph, segmentIDs: ["c1"])],
                                             segments: segments, includesMarkers: false))
    }

    func testLayoutRejectsMissingReasonRepeatedUnknownAndEmptyGroups() throws {
        let segments = try Plan.segments(in: "先等待。因为仓库停电。明早处理。")
        let invalid: [Any] = [
            [["style": "paragraph", "segment_ids": ["c1", "c3"]]],
            [["style": "paragraph", "segment_ids": ["c1", "c2", "c2", "c3"]]],
            [["style": "paragraph", "segment_ids": ["c1", "c2", "c4"]]],
            [["style": "paragraph", "segment_ids": [String]()]],
            [["style": "paragraph", "segment_ids": ["c1", "c2"]], ["style": "bullet", "segment_ids": ["c2", "c3"]]],
            [], NSNull(), "c1,c2,c3"
        ]
        for object in invalid {
            XCTAssertThrowsError(try Plan.decodeLayout(from: object, segments: segments))
        }
    }

    func testLayoutRejectsFreeTextTitlesUnknownStylesAndNonStringIDs() throws {
        let segments = try Plan.segments(in: "正文不能改。")
        let invalid: [Any] = [
            [["style": "paragraph", "segment_ids": ["c1"], "text": "替换正文"]],
            [["style": "paragraph", "segment_ids": ["c1"], "title": "新增标题"]],
            [["style": "heading", "segment_ids": ["c1"]]],
            [["style": " paragraph", "segment_ids": ["c1"]]],
            [["style": "paragraph", "segment_ids": [1]]],
            [["style": "paragraph", "segment_ids": [true]]],
            [["style": "paragraph", "segment_ids": "c1"]],
            [["segment_ids": ["c1"]]],
            [["style": "paragraph", "segment_ids": ["c1\u{0000}"]]],
            ["layout": [["style": "paragraph", "segment_ids": ["c1"]]]]
        ]
        for object in invalid {
            XCTAssertThrowsError(try Plan.decodeLayout(from: object, segments: segments))
        }
    }

    func testRenderRechecksCoverageWhenCallerBypassesDecoder() throws {
        let segments = try Plan.segments(in: "正文。有效原因。")
        for blocks in [[Plan.Block(style: .paragraph, segmentIDs: ["c1"])],
                       [Plan.Block(style: .bullet, segmentIDs: ["c1", "c1", "c2"])],
                       [Plan.Block(style: .numbered, segmentIDs: ["c1", "c9"])],
                       [Plan.Block(style: .paragraph, segmentIDs: [])]] {
            XCTAssertThrowsError(try Plan.render(blocks, segments: segments))
        }
    }

    func testLineLeadingCodeFencesRequireParagraphStyleInDecoderAndRenderer() throws {
        for code in ["```swift\nprint(1)\n```", "说明\r\n  ~~~text\r\n保留。\r\n  ~~~",
                     "\t````text\n原文\n````"] {
            let segments = [Plan.Segment(id: "c1", text: "代码说明。"), .init(id: "c2", text: code)]
            let paragraph = [Plan.Block(style: .paragraph, segmentIDs: ["c1"]),
                             Plan.Block(style: .paragraph, segmentIDs: ["c2"])]
            XCTAssertEqual(try Plan.render(paragraph, segments: segments), "代码说明。\n\n" + code)
            XCTAssertNoThrow(try Plan.decodeLayout(from: [["style": "paragraph", "segment_ids": ["c1"]],
                                                         ["style": "paragraph", "segment_ids": ["c2"]]], segments: segments))
            for style in [Plan.Style.bullet, .numbered] {
                XCTAssertThrowsError(try Plan.decodeLayout(from: [["style": style.rawValue, "segment_ids": ["c1", "c2"]]], segments: segments))
                let blocks = [Plan.Block(style: style, segmentIDs: ["c1", "c2"])]
                XCTAssertThrowsError(try Plan.render(blocks, segments: segments))
                XCTAssertThrowsError(try Plan.render(blocks, segments: segments, includesMarkers: false))
            }
            for ids in [["c1", "c2"], ["c2", "c1"]] {
                XCTAssertThrowsError(try Plan.decodeLayout(from: [["style": "paragraph", "segment_ids": ids]], segments: segments))
                XCTAssertThrowsError(try Plan.render([.init(style: .paragraph, segmentIDs: ids)], segments: segments))
            }
            XCTAssertEqual(try Plan.render([.init(style: .paragraph, segmentIDs: ["c2"]),
                                           .init(style: .paragraph, segmentIDs: ["c1"])], segments: segments),
                           code + "\n\n代码说明。")
        }
        let inline = try Plan.segments(in: "执行 `swift test`。")
        let bullet = try Plan.decodeLayout(from: [["style": "bullet", "segment_ids": ["c1"]]], segments: inline)
        XCTAssertEqual(try Plan.render(bullet, segments: inline), "- 执行 `swift test`。")
    }

    func testIndentedCodeRequiresItsOwnParagraphInDecoderAndBothRenderViews() throws {
        for code in ["    if ready:\n        send()", "\tif ready:\n\tsend()", "  \tcall()", "\r\n    code()"] {
            let segments = try Plan.segments(in: code)
            XCTAssertEqual(segments, [.init(id: "c1", text: code)])
            let paragraph = [Plan.Block(style: .paragraph, segmentIDs: ["c1"])]
            XCTAssertEqual(try Plan.render(paragraph, segments: segments), code)
            XCTAssertEqual(try Plan.render(paragraph, segments: segments, includesMarkers: false), code)
            for style in [Plan.Style.bullet, .numbered] {
                XCTAssertThrowsError(try Plan.decodeLayout(from: [["style": style.rawValue, "segment_ids": ["c1"]]], segments: segments))
                for markers in [true, false] {
                    XCTAssertThrowsError(try Plan.render([.init(style: style, segmentIDs: ["c1"])],
                                                        segments: segments, includesMarkers: markers))
                }
            }
            let withProse = segments + [.init(id: "c2", text: "正文说明。")]
            for ids in [["c1", "c2"], ["c2", "c1"]] {
                XCTAssertThrowsError(try Plan.decodeLayout(from: [["style": "paragraph", "segment_ids": ids]], segments: withProse))
                XCTAssertThrowsError(try Plan.render([.init(style: .paragraph, segmentIDs: ids)], segments: withProse))
            }
        }
        for spaces in 0...3 {
            let prefix = String(repeating: " ", count: spaces)
            let segments = try Plan.segments(in: prefix + "普通正文。")
            let bullet = try Plan.decodeLayout(from: [["style": "bullet", "segment_ids": ["c1"]]], segments: segments)
            XCTAssertEqual(try Plan.render(bullet, segments: segments), prefix + "- 普通正文。")
        }
    }

    func testListMarkersFollowOriginalLeadingWhitespaceInsteadOfCreatingEmptyItems() throws {
        let source = "先检查。\n\n再发布。"
        let segments = try Plan.segments(in: source)
        let blocks = [Plan.Block(style: .numbered, segmentIDs: ["c1"]),
                      Plan.Block(style: .numbered, segmentIDs: ["c2"])]
        XCTAssertEqual(try Plan.render(blocks, segments: segments), "1. 先检查。\n\n2. 再发布。")
        XCTAssertEqual(Array(try Plan.render(blocks, segments: segments, includesMarkers: false).utf8), Array(source.utf8))
        for prefix in ["", "\n\n", "  ", "\u{00A0}", "\r\n  "] {
            let item = [Plan.Segment(id: "c1", text: prefix + "正文。")]
            for (style, marker) in [(Plan.Style.bullet, "- "), (.numbered, "1. ")] {
                let one = [Plan.Block(style: style, segmentIDs: ["c1"])]
                XCTAssertEqual(try Plan.render(one, segments: item), prefix + marker + "正文。")
                XCTAssertEqual(try Plan.render(one, segments: item, includesMarkers: false), prefix + "正文。")
            }
        }
    }

    func testGroupSeparatorsOnlyAddMissingNewlinesAndPreserveEveryOriginalByte() throws {
        let cases = [
            ("甲", "乙", "甲\n\n乙"),
            ("甲\n", "乙", "甲\n\n乙"),
            ("甲", "\n\n乙", "甲\n\n乙"),
            ("甲\r\n", "\r\n乙", "甲\r\n\r\n乙"),
            ("甲\r", "\n乙", "甲\r\n\n乙"),
            ("甲\r", "乙", "甲\r\n\n乙"),
            ("甲 \n ", " \n乙", "甲 \n  \n乙"),
            ("甲\r ", " \n乙", "甲\r  \n乙"),
            ("甲\n\n\n", "\n乙", "甲\n\n\n\n乙"),
            ("甲", "\u{2028}乙", "甲\n\u{2028}乙")
        ]
        for (first, second, expected) in cases {
            let segments = [Plan.Segment(id: "c1", text: first), .init(id: "c2", text: second)]
            let blocks = [Plan.Block(style: .paragraph, segmentIDs: ["c1"]),
                          Plan.Block(style: .paragraph, segmentIDs: ["c2"])]
            for markers in [true, false] {
                let rendered = try Plan.render(blocks, segments: segments, includesMarkers: markers)
                XCTAssertEqual(Array(rendered.utf8), Array(expected.utf8), "\(first.debugDescription) / \(second.debugDescription)")
                XCTAssertTrue(rendered.utf8.starts(with: first.utf8))
                XCTAssertTrue(rendered.utf8.suffix(second.utf8.count).elementsEqual(second.utf8))
            }
        }
    }

    func testSegmentLimitCombinesRemainderWithoutOmittingText() throws {
        let source = String(repeating: "处理。", count: 140)
        let segments = try Plan.segments(in: source)
        XCTAssertEqual(segments.count, 128)
        XCTAssertEqual(segments.last, .init(id: "c128", text: String(repeating: "处理。", count: 13)))
        assertBytesPreserved(segments, source: source)
        XCTAssertEqual(try Plan.render([.init(style: .paragraph, segmentIDs: segments.map(\.id))], segments: segments), source)
    }

    func testInvalidSourceSegmentIDsAndControlCharactersAreRejected() {
        for source in ["", " \r\n\t", "文字\u{0000}", "文字\u{007F}", "文字\u{0085}"] {
            XCTAssertThrowsError(try Plan.segments(in: source))
        }
        for segments in [[Plan.Segment](), [.init(id: "c2", text: "正文")],
                         [.init(id: "c1", text: "正文"), .init(id: "c1", text: "重复ID")],
                         [.init(id: "c1", text: "")], [.init(id: "c1", text: "\u{0000}")],
                         [.init(id: "c1", text: " ")]] {
            XCTAssertThrowsError(try Plan.render([.init(style: .paragraph, segmentIDs: ["c1"])], segments: segments))
        }
    }

    func testOutputAndLayoutCapacityLimitsAreEnforced() throws {
        let maximum = String(repeating: "a", count: Plan.maximumOutputBytes)
        let segments = [Plan.Segment(id: "c1", text: maximum)]
        XCTAssertEqual(try Plan.render([.init(style: .paragraph, segmentIDs: ["c1"])], segments: segments).utf8.count,
                       Plan.maximumOutputBytes)
        XCTAssertThrowsError(try Plan.render([.init(style: .bullet, segmentIDs: ["c1"])], segments: segments)) {
            XCTAssertEqual($0 as? VoicePolishStructurePlanError, .outputTooLong)
        }
        XCTAssertThrowsError(try Plan.segments(in: maximum + "a"))
        let tooMany = Array(repeating: ["style": "paragraph", "segment_ids": ["c1"]] as [String: Any], count: 129)
        XCTAssertThrowsError(try Plan.decodeLayout(from: tooMany, segments: segments))
        XCTAssertThrowsError(try Plan.decodeLayout(from: [["style": "paragraph", "segment_ids": Array(repeating: "c1", count: 129)]],
                                                  segments: segments))
    }

    func testLayoutAndSegmentsEncodeOnlyTheirExplicitFields() throws {
        let block = Plan.Block(style: .bullet, segmentIDs: ["c1"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["style", "segment_ids"])
        XCTAssertEqual(object["segment_ids"] as? [String], ["c1"])
        let segment = Plan.Segment(id: "c1", text: "原文🙂")
        XCTAssertEqual(try JSONDecoder().decode(Plan.Segment.self, from: JSONEncoder().encode(segment)), segment)
    }

    private func assertBytesPreserved(_ segments: [Plan.Segment], source: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(segments.map(\.text).joined().utf8), Array(source.utf8), file: file, line: line)
        XCTAssertEqual(segments.map(\.id), segments.indices.map { "c\($0 + 1)" }, file: file, line: line)
    }
}
