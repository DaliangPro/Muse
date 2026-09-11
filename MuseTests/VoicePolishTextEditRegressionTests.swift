import XCTest
@testable import Muse

final class VoicePolishTextEditRegressionTests: XCTestCase {
    func test符号恢复可同时补标点但不能改变正文或技术含义() throws {
        let source = "swift build短横线c release第三执行"
        XCTAssertEqual(try apply([
            .init(before: source, after: "swift build -c release，第三执行", kind: .symbol)
        ], to: source), "swift build -c release，第三执行")
        for output in ["swift build -c debug，第三执行", "swift build c release，第三执行",
                       "swift build -c release。\n第三执行"] {
            XCTAssertThrowsError(try apply([
                .init(before: source, after: output, kind: .symbol)
            ], to: source))
        }
        let path = "scripts斜杠package短横线app点sh等一下"
        XCTAssertEqual(try apply([
            .init(before: path, after: "scripts/package-app.sh，等一下", kind: .symbol)
        ], to: path), "scripts/package-app.sh，等一下")
    }
    private func apply(_ edits: [VoicePolishTextEdit], to source: String,
                       mode: VoicePolishQualityMode = .light,
                       allowsReviewedSourceCorrections: Bool = false) throws -> String {
        try VoicePolishTextEditor.apply(edits, to: source, source: source, mode: mode,
                                       allowsReviewedSourceCorrections: allowsReviewedSourceCorrections)
    }

    func test真实聊天补丁仅删除填充声并保留定位正文() throws {
        // 2026-09-11 light13 / chat-01 的原始输入与 Provider 补丁。
        let source = "嗯我今天大概七点半到你们不用等我吃饭先吃就行"
        let edits = try VoicePolishTextEditor.decode(#"{"edits":[{"before":"嗯我今天","after":"我今天","kind":"filler"}]}"#)
        XCTAssertEqual(try apply(edits, to: source), "我今天大概七点半到你们不用等我吃饭先吃就行")
    }

    func test真实代码补丁共享四步上下文但插入位置独立() throws {
        // 仅验证真实补丁的机械执行，不把仍含口述改口过程的输出评为质量通过。
        let source = "部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用"
        let edits = try VoicePolishTextEditor.decode(#"{"edits":[{"before":"三步第一跑","after":"三步，第一跑","kind":"punctuation"},{"before":"swift test第二跑","after":"swift test，第二跑","kind":"punctuation"},{"before":"swift build短横线c release","after":"swift build -c release","kind":"symbol"},{"before":"第三执行scripts斜杠package短横线app点sh","after":"第三执行scripts/package-app.sh","kind":"symbol"},{"before":"等一下还有一步","after":"等一下，还有一步","kind":"punctuation"},{"before":"codesign所以一共四步","after":"codesign，所以一共四步","kind":"punctuation"},{"before":"四步最后再启动应用","after":"四步，最后再启动应用","kind":"punctuation"}]}"#)
        XCTAssertEqual(try apply(edits, to: source), "部署要做三步，第一跑swift test，第二跑swift build -c release第三执行scripts/package-app.sh等一下，还有一步要检查codesign，所以一共四步，最后再启动应用")
    }

    func test一个锚点多个插入不占用中间未修改文字() throws {
        let source = "先按装再启动最后检查"
        let edits: [VoicePolishTextEdit] = [
            .init(before: source, after: "先按装，再启动，最后检查", kind: .punctuation),
            .init(before: "按装再启动", after: "安装再启动", kind: .word)
        ]
        XCTAssertEqual(try apply(edits, to: source), "先安装，再启动，最后检查")
        XCTAssertEqual(try apply(Array(edits.reversed()), to: source), "先安装，再启动，最后检查")
    }

    func test相同位置相同插入只提交一次() throws {
        let source = "甲乙丙"
        XCTAssertEqual(try apply([
            .init(before: "甲乙", after: "甲，乙", kind: .punctuation),
            .init(before: "乙丙", after: "，乙丙", kind: .punctuation)
        ], to: source), "甲，乙丙")
    }

    func test相同位置不同插入拒绝整批补丁() {
        let source = "甲乙丙"
        XCTAssertThrowsError(try apply([
            .init(before: "甲乙", after: "甲，乙", kind: .punctuation),
            .init(before: "乙丙", after: "。乙丙", kind: .punctuation)
        ], to: source)) { XCTAssertEqual($0 as? VoicePolishTextEditError, .overlappingEdits) }
    }

    func test实际修改冲突仍拒绝即使锚点各自唯一() {
        let source = "先按装软件"
        XCTAssertThrowsError(try apply([
            .init(before: "先按装", after: "先安装", kind: .word),
            .init(before: "按装软件", after: "换装软件", kind: .word)
        ], to: source)) { XCTAssertEqual($0 as? VoicePolishTextEditError, .overlappingEdits) }
    }

    func test修改区内部插入不能与替换合并() {
        let source = "甲乙"
        XCTAssertThrowsError(try apply([
            .init(before: source, after: "丙丁", kind: .content, evidence: source),
            .init(before: source, after: "甲，乙", kind: .content, evidence: source)
        ], to: source, mode: .standard)) {
            XCTAssertEqual($0 as? VoicePolishTextEditError, .overlappingEdits)
        }
    }

    func test修改区两侧插入顺序确定且不受补丁顺序影响() throws {
        let source = "前甲乙后"
        let edits: [VoicePolishTextEdit] = [
            .init(before: "甲乙", after: "丙丁", kind: .content, evidence: source),
            .init(before: "前甲", after: "前，甲", kind: .content, evidence: source),
            .init(before: "乙后", after: "乙。后", kind: .content, evidence: source)
        ]
        XCTAssertEqual(try apply(edits, to: source, mode: .standard), "前，丙丁。后")
        XCTAssertEqual(try apply(Array(edits.reversed()), to: source, mode: .standard), "前，丙丁。后")
    }

    func testUnicode组合字符与表情后的多个插入保持准确位置() throws {
        let source = "👨‍👩‍👧‍👦嗯我今天用e\u{301}看结果👍🏽再发送"
        XCTAssertEqual(try apply([
            .init(before: "嗯我今天", after: "我今天", kind: .filler),
            .init(before: "今天用e\u{301}看结果👍🏽再发送", after: "今天用e\u{301}，看结果👍🏽，再发送。", kind: .punctuation)
        ], to: source), "👨‍👩‍👧‍👦我今天用e\u{301}，看结果👍🏽，再发送。")
    }

    func testUnicode规范形式替换不会被忽略() throws {
        let source = "前e\u{301}后"
        let output = try apply([
            .init(before: "e\u{301}", after: "é", kind: .content, evidence: source)
        ], to: source, mode: .standard)
        XCTAssertEqual(Array(output.utf8), Array("前é后".utf8))
    }

    func test口吃校验仍能读取完整重复证据() throws {
        let source = "我我今天按装软件"
        XCTAssertEqual(try apply([
            .init(before: "我我今天", after: "我今天", kind: .stutter),
            .init(before: "今天按装", after: "今天安装", kind: .word)
        ], to: source), "我今天安装软件")
        XCTAssertEqual(try apply([
            .init(before: "我我我今今天", after: "我今天", kind: .stutter)
        ], to: "我我我今今天"), "我今天")
        XCTAssertThrowsError(try apply([
            .init(before: "检查文件并发送文件", after: "发送文件", kind: .stutter)
        ], to: "检查文件并发送文件"))
    }

    func test填充声补丁不能混删实词或技术符号() throws {
        for source in ["嗯今天要发送", "嗯+参数", "嗯_参数", "嗯/参数", "嗯`参数", "嗯.参数", "嗯:参数"] {
            let output = source == "嗯今天要发送" ? "发送" : "参数"
            XCTAssertThrowsError(try apply([
                .init(before: source, after: output, kind: .filler)
            ], to: source), source)
        }
        XCTAssertThrowsError(try apply([
            .init(before: "嗯今天", after: "明天", kind: .filler)
        ], to: "嗯今天"))
        XCTAssertThrowsError(try apply([
            .init(before: "嗯嗯嗯嗯嗯嗯嗯今天", after: "今天", kind: .filler)
        ], to: "嗯嗯嗯嗯嗯嗯嗯今天"))
        XCTAssertEqual(try apply([
            .init(before: "嗯今天呃发送", after: "今天发送", kind: .filler)
        ], to: "嗯今天呃发送"), "今天发送")
    }

    func test重叠出现的原文锚点也不唯一() {
        XCTAssertThrowsError(try apply([
            .init(before: "哈哈", after: "哈", kind: .stutter)
        ], to: "哈哈哈")) { XCTAssertEqual($0 as? VoicePolishTextEditError, .ambiguousAnchor) }
    }

    func test坏补丁不会被忽略后返回部分修改() {
        let source = "嗯今天要发送"
        XCTAssertThrowsError(try apply([
            .init(before: "嗯今天", after: "今天", kind: .filler),
            .init(before: "今天要发送", after: "发送", kind: .filler)
        ], to: source)) { XCTAssertEqual($0 as? VoicePolishTextEditError, .editOutsideMode) }
    }

    func test当前编辑前缀可用口述逗号句号或多句结束() throws {
        for ending in ["：", ":", "，", ",", "。", "."] {
            let prefix = "给客户回一下" + ending
            let source = prefix + "我们已收到材料。"
            XCTAssertEqual(try apply([
                .init(before: prefix, after: "", kind: .directive)
            ], to: source), "我们已收到材料。")
        }
        let prefix = "帮我整理成 Prompt。先别开始研究，只整理任务，"
        let source = prefix + "请比较两款产品，保留价格来源。"
        XCTAssertEqual(try apply([
            .init(before: prefix, after: "", kind: .directive)
        ], to: source), "请比较两款产品，保留价格来源。")
    }

    func test编辑前缀仍受位置长度及非全文限制() {
        let longPrefix = "帮我整理成 Prompt，会议周五举行，预算一万六，负责人小李，要保留全部约束，"
        XCTAssertGreaterThan(longPrefix.count, 32)
        for (source, anchor) in [
            (longPrefix + "请核对。", longPrefix),
            ("给同事的任务是，给客户回一下，材料已收到。", "给客户回一下，"),
            ("帮我整理成 Prompt。", "帮我整理成 Prompt。")
        ] {
            XCTAssertThrowsError(try apply([
                .init(before: anchor, after: "", kind: .directive)
            ], to: source)) { XCTAssertEqual($0 as? VoicePolishTextEditError, .editOutsideMode) }
        }
    }

    func test有原文证据的远处改口只能经显式核对权限预览() throws {
        let before = "小李负责看是否有重复报名"
        let after = "小赵负责看是否有重复报名"
        let evidence = "重复报名的检查改由小赵来做"
        let middle = String(repeating: "其他事项逐项记录，当前负责人安排不要遗漏。", count: 20)
        let source = before + "。\n\n" + middle + "\n\n" + evidence + "。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let edits: [VoicePolishTextEdit] = [.init(before: before, after: after, kind: .correction, evidence: evidence)]
        XCTAssertThrowsError(try apply(edits, to: source))
        XCTAssertEqual(try apply(edits, to: source, allowsReviewedSourceCorrections: true),
                       after + "。\n\n" + middle + "\n\n" + evidence + "。")
    }

    func test远处改口证据必须存在且不超长并包含明确改口提示() {
        let longEvidence = "改由小赵" + String(repeating: "说明", count: 96)
        for (sourceTail, evidence) in [
            ("检查改由小赵来做。", nil),
            ("检查改由小赵来做。", "不存在的检查改由小赵来做"),
            ("检查交给小赵来做。", "检查交给小赵来做。"),
            (longEvidence, longEvidence)
        ] as [(String, String?)] {
            let source = "小李负责检查。" + sourceTail
            XCTAssertThrowsError(try apply([
                .init(before: "小李负责检查", after: "小赵负责检查", kind: .correction, evidence: evidence)
            ], to: source, allowsReviewedSourceCorrections: true))
        }
    }

    func test远处改口不能从证据散字拼接新名称() {
        let evidence = "改由赵老师处理，敏同学协助确认。"
        let source = "阿文负责检查。" + evidence
        XCTAssertThrowsError(try apply([
            .init(before: "阿文负责检查", after: "赵敏负责检查", kind: .correction, evidence: evidence)
        ], to: source, allowsReviewedSourceCorrections: true))
    }

    func test远处改口仍限制单个实质修改块和修改长度() {
        let cases = [
            ("甲检查乙发送", "乙发送甲检查"),
            ("小李检查小王发送", "小赵检查小刘发送"),
            (String(repeating: "甲", count: 33), "乙"),
            ("甲", String(repeating: "乙", count: 9)),
            (String(repeating: "说明", count: 48) + "甲", String(repeating: "说明", count: 48) + "乙")
        ]
        for (before, after) in cases {
            let evidence = "改成" + after
            let source = before + "。" + evidence
            XCTAssertThrowsError(try apply([
                .init(before: before, after: after, kind: .correction, evidence: evidence)
            ], to: source, allowsReviewedSourceCorrections: true), before)
        }
    }

    func test远处改口不能损坏路径标识符或技术标点() {
        for (before, after) in [("foo_bar", "foobar"), ("git --hard", "git hard"),
                                ("/tmp/file", "tmp/file"), ("main.swift", "mainswift"),
                                ("10:30", "1030"), ("A+B", "AB")] {
            let evidence = "改成" + after
            XCTAssertThrowsError(try apply([
                .init(before: before, after: after, kind: .correction, evidence: evidence)
            ], to: before + "。" + evidence, allowsReviewedSourceCorrections: true), before)
        }
    }

    func test旧近邻改口仍可用并识别改由() throws {
        for (source, output) in [("预算一万六，不对，一万五。", "预算一万五。"),
                                 ("负责人小李，改由小赵。", "负责人小赵。")] {
            XCTAssertEqual(try apply([
                .init(before: source, after: output, kind: .correction)
            ], to: source), output)
        }
    }

    func test轻度不能删除移动或新增任何原有换行() {
        for newline in ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            for (before, after) in [("甲" + newline + "乙丙", "甲乙丙"),
                                    ("甲" + newline + "乙丙", "甲乙" + newline + "丙"),
                                    ("甲乙丙", "甲" + newline + "乙丙")] {
                XCTAssertThrowsError(try apply([
                    .init(before: before, after: after, kind: .punctuation)
                ], to: before), "换行=\(newline.unicodeScalars.map(\.value)), before=\(before.debugDescription), after=\(after.debugDescription)")
            }
        }
        let source = "预算一万六，不对，\n一万五。"
        XCTAssertThrowsError(try apply([
            .init(before: source, after: "预算一万五。", kind: .correction)
        ], to: source, allowsReviewedSourceCorrections: true))
        let command = "swift build短横线c release\n随后检查"
        XCTAssertThrowsError(try apply([
            .init(before: command, after: "swift build -c release随后检查", kind: .symbol)
        ], to: command))
        for (before, after, kind) in [
            ("我\r\n我我今天", "我我\r\n今天", VoicePolishTextEdit.Kind.stutter),
            ("甲\r\n乙丙，不对", "甲乙\r\n丙", .correction),
            ("小李\r\n负责检查", "小赵负责\r\n检查", .correction),
            ("按装\r\n软件", "安\r\n装软件", .word)
        ] {
            let evidence = "改由小赵负责检查"
            XCTAssertThrowsError(try apply([
                .init(before: before, after: after, kind: kind, evidence: evidence)
            ], to: before + "。" + evidence, allowsReviewedSourceCorrections: true), "\(kind): \(before.debugDescription)")
        }
    }

    func test远处改口锚点可以跨段但必须逐字保留换行() throws {
        let before = "小李负责\n检查重复报名"
        let after = "小赵负责\n检查重复报名"
        let evidence = "重复报名检查改由小赵来做"
        let source = before + "。\n\n" + evidence
        XCTAssertEqual(try apply([
            .init(before: before, after: after, kind: .correction, evidence: evidence)
        ], to: source, allowsReviewedSourceCorrections: true), after + "。\n\n" + evidence)
        XCTAssertThrowsError(try apply([
            .init(before: before, after: "小赵负责检查重复报名", kind: .correction, evidence: evidence)
        ], to: source, allowsReviewedSourceCorrections: true))
    }
}
