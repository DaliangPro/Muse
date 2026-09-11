import XCTest
@testable import Muse

final class VoicePolishContentEditPermissionTests: XCTestCase {
    func test标准内容入口允许局部类型并保留其语义复核要求() throws {
        let cases: [(String, String, VoicePolishTextEdit.Kind)] = [
            ("明天见", "明天见。", .punctuation),
            ("我我今天发送", "我今天发送", .stutter),
            ("按装软件", "安装软件", .word),
            ("scripts斜杠check点sh", "scripts/check.sh", .symbol),
            ("周三，不对，周四开会", "周四开会", .correction),
            ("嗯今天发送", "今天发送", .filler),
            ("请整理：今天发送", "今天发送", .directive)
        ]
        for (before, after, kind) in cases {
            let edit = VoicePolishTextEdit(before: before, after: after, kind: kind)
            XCTAssertEqual(try apply([edit], to: before, reviewedDirectives: true), after, "\(kind)")
        }
        let edit = VoicePolishTextEdit(before: "周三，不对，周四开会", after: "周四开会", kind: .correction)
        XCTAssertTrue(VoicePolishTextEditor.requiresSemanticReview([edit], in: edit.before))
    }

    func test标准内容入口不因有效原文证据获得自由重写权限() throws {
        let source = "因为下午有事，改由同事负责检查。"
        let edit = VoicePolishTextEdit(before: source, after: "同事负责检查。", kind: .content, evidence: source)
        XCTAssertThrowsError(try apply([edit], to: source)) {
            XCTAssertEqual($0 as? VoicePolishTextEditError, .editOutsideMode)
        }
        // 旧入口仅供旧管线兼容；此断言防止新入口误接到它的宽松策略。
        XCTAssertEqual(try VoicePolishTextEditor.apply([edit], to: source, source: source, mode: .standard), edit.after)
    }

    func test标准内容入口拒绝把局部修改伪装成content类型() {
        let edit = VoicePolishTextEdit(before: "明天见", after: "明天见。", kind: .content, evidence: "明天见")
        XCTAssertThrowsError(try apply([edit], to: edit.before))
    }

    func test近邻改口的纯删除总量在三十二标量边界内才可预览() throws {
        for amount in [32, 33] {
            let removed = "不对" + String(repeating: "甲", count: amount - 2)
            let source = removed + "乙"
            let edit = VoicePolishTextEdit(before: source, after: "乙", kind: .correction)
            XCTAssertLessThanOrEqual(source.count, 96)
            if amount == 32 {
                XCTAssertEqual(try apply([edit], to: source), "乙")
                XCTAssertTrue(VoicePolishTextEditor.requiresSemanticReview([edit], in: source))
            } else {
                XCTAssertThrowsError(try apply([edit], to: source))
                XCTAssertThrowsError(try VoicePolishTextEditor.apply([edit], to: source, source: source, mode: .light))
            }
        }
    }

    func test改口的多个删除块按总量计数而不是逐块放行() throws {
        for amount in [32, 33] {
            let first = "不对" + String(repeating: "甲", count: 14)
            let second = String(repeating: "丙", count: amount - 16)
            let source = first + "乙" + second + "丁"
            let edit = VoicePolishTextEdit(before: source, after: "乙丁", kind: .correction)
            if amount == 32 {
                XCTAssertEqual(try apply([edit], to: source), "乙丁")
            } else {
                XCTAssertThrowsError(try apply([edit], to: source))
            }
        }
    }

    func test合法嵌套时间改口可删除多个短块但仍需语义复核() throws {
        let source = "周三上午十点不对周四上午十点哎十点半才对"
        let edit = VoicePolishTextEdit(before: source, after: "周四上午十点半", kind: .correction)
        XCTAssertEqual(try apply([edit], to: source), edit.after)
        XCTAssertEqual(try VoicePolishTextEditor.apply([edit], to: source, source: source, mode: .light), edit.after)
        XCTAssertTrue(VoicePolishTextEditor.requiresSemanticReview([edit], in: source))
    }

    func test短锚点含改口词也不能大段删掉正文() {
        let source = "不对，" + String(repeating: "进度原因条件和负责事项都需要保留", count: 3) + "最后继续。"
        XCTAssertLessThanOrEqual(source.count, 96)
        let edit = VoicePolishTextEdit(before: source, after: "最后继续。", kind: .correction)
        XCTAssertThrowsError(try apply([edit], to: source))
    }

    func test近邻改口不能借改口词删除技术符号() {
        for token in ["foo_bar", "git --hard", "/tmp/file", "main.swift", "10:30", "A+B"] {
            let source = token + "，不对，保留参数。"
            let edit = VoicePolishTextEdit(before: source, after: "保留参数。", kind: .correction)
            XCTAssertThrowsError(try apply([edit], to: source), token)
        }
    }

    func test近邻改口的实质预算按标量计数不按组合字符低估() {
        // 每个韩文组合字由两个字母标量组成，不借技术符号保护使本例提前失败。
        let source = "不对" + String(repeating: "\u{1100}\u{1161}", count: 16) + "结果"
        XCTAssertLessThanOrEqual(source.count, 32)
        let edit = VoicePolishTextEdit(before: source, after: "结果", kind: .correction)
        XCTAssertThrowsError(try apply([edit], to: source))
    }

    func test近邻ASCII时间改口可移除完整旧钟面并保留最终钟面() throws {
        for (source, output) in [
            ("会议10:30，不对，10:45开始。", "会议10:45开始。"),
            ("会议9:05，不对，09:15开始。", "会议09:15开始。"),
            ("会议9:05不对9:15不对9:25开始。", "会议9:25开始。"),
            ("第一场10:30，不对，10:45，第二场12:00。", "第一场10:45，第二场12:00。")
        ] {
            let edit = VoicePolishTextEdit(before: source, after: output, kind: .correction)
            XCTAssertEqual(try apply([edit], to: source), output)
            XCTAssertEqual(try VoicePolishTextEditor.apply([edit], to: source, source: source, mode: .light), output)
            XCTAssertTrue(VoicePolishTextEditor.requiresSemanticReview([edit], in: source))
        }
    }

    func test时间豁免不能造新钟面删冒号造数字或清空全部钟面() {
        let source = "会议10:30，不对，10:45开始，后续12:00继续。"
        for output in ["会议10:55开始，后续12:00继续。", "会议1045开始，后续12:00继续。",
                       "会议开始，后续继续。", "会议10:45开始，后续1200继续。"] {
            XCTAssertThrowsError(try apply([.init(before: source, after: output, kind: .correction)], to: source), output)
        }
        let oversized = "会议10:30" + String(repeating: "甲", count: 32) + "不对10:45开始。"
        XCTAssertThrowsError(try apply([.init(before: oversized, after: "会议10:45开始。", kind: .correction)], to: oversized))
    }

    func test时间豁免不能把路径端口标识符和非完整时钟当作旧钟面() {
        for prefix in ["host:", "foo", "λ", "/tmp/", "`", "_", "110", "["] {
            let anchor = "10:30不对10:45"
            let source = prefix + anchor
            // 刻意裁去左侧技术字符，仍必须按真实稿邻接判定边界。
            XCTAssertThrowsError(try apply([.init(before: anchor, after: "10:45", kind: .correction)], to: source), prefix)
        }
        for (source, output) in [("10:30.log不对10:45", "10:45"), ("10:30:90不对10:45", "10:45"),
                                 ("25:30不对10:45", "10:45"), ("10:65不对10:45", "10:45"),
                                 ("10:30\u{301}不对10:45", "10:45")] {
            XCTAssertThrowsError(try apply([.init(before: source, after: output, kind: .correction)], to: source), source)
        }
    }

    func test时间豁免不能混删其他技术字符或拓宽远处改口权限() {
        let source = "运行A+B，会议10:30不对10:45开始。"
        XCTAssertThrowsError(try apply([.init(before: source, after: "运行AB，会议10:45开始。", kind: .correction)], to: source))
        let draft = "安排10:30和10:45开始。"
        let evidence = "改成10:45开始"
        XCTAssertThrowsError(try apply([
            .init(before: draft, after: "安排10:45开始。", kind: .correction, evidence: evidence)
        ], to: draft, source: draft + evidence, reviewedCorrections: true))
    }

    func test远处改口仍要求原文证据和显式复核权限() throws {
        let draft = "阿文负责检查。\n其他事项保持。"
        let evidence = "检查改由阿宁来做"
        let source = draft + "\n" + evidence
        let edit = VoicePolishTextEdit(before: "阿文负责检查。", after: "阿宁负责检查。", kind: .correction, evidence: evidence)
        XCTAssertThrowsError(try apply([edit], to: draft, source: source))
        XCTAssertEqual(try apply([edit], to: draft, source: source, reviewedCorrections: true),
                       "阿宁负责检查。\n其他事项保持。")
        XCTAssertThrowsError(try apply([edit], to: draft, source: draft, reviewedCorrections: true))
    }

    func test远处改口仍限制一次实质替换与八标量插入预算() throws {
        for amount in [8, 9] {
            let output = String(repeating: "乙", count: amount)
            let evidence = "改成" + output
            let edit = VoicePolishTextEdit(before: "甲", after: output, kind: .correction, evidence: evidence)
            if amount == 8 {
                XCTAssertEqual(try apply([edit], to: "甲", source: "甲。" + evidence, reviewedCorrections: true), output)
            } else {
                XCTAssertThrowsError(try apply([edit], to: "甲", source: "甲。" + evidence, reviewedCorrections: true))
            }
        }
        let evidence = "改成乙做一项丁做二项"
        let edit = VoicePolishTextEdit(before: "甲做一项丙做二项", after: "乙做一项丁做二项", kind: .correction, evidence: evidence)
        XCTAssertThrowsError(try apply([edit], to: edit.before, source: edit.before + evidence, reviewedCorrections: true))
    }

    func test标准内容入口仍保护原段落和技术词边界() {
        for (source, output) in [("甲\n乙丙", "甲乙\n丙"), ("swift test", "swifttest"),
                                 ("foo_bar", "foobar"), ("甲乙", "甲\n乙")] {
            XCTAssertThrowsError(try apply([
                .init(before: source, after: output, kind: .punctuation)
            ], to: source), source)
        }
    }

    func test标准内容入口仍拒绝歧义锚点和冲突实际变化() {
        XCTAssertThrowsError(try apply([
            .init(before: "今天", after: "今天，", kind: .punctuation)
        ], to: "今天见今天发")) {
            XCTAssertEqual($0 as? VoicePolishTextEditError, .ambiguousAnchor)
        }
        XCTAssertThrowsError(try apply([
            .init(before: "先按装", after: "先安装", kind: .word),
            .init(before: "按装软件", after: "换装软件", kind: .word)
        ], to: "先按装软件")) {
            XCTAssertEqual($0 as? VoicePolishTextEditError, .overlappingEdits)
        }
    }

    func test标准内容入口依实际变化组合补丁并保持原子提交() throws {
        let source = "先按装再启动最后检查"
        let edits: [VoicePolishTextEdit] = [
            .init(before: source, after: "先按装，再启动，最后检查", kind: .punctuation),
            .init(before: "按装再启动", after: "安装再启动", kind: .word)
        ]
        XCTAssertEqual(try apply(edits, to: source), "先安装，再启动，最后检查")
        XCTAssertEqual(try apply(Array(edits.reversed()), to: source), "先安装，再启动，最后检查")
        XCTAssertThrowsError(try apply(edits + [
            .init(before: "最后检查", after: "发布完毕", kind: .content, evidence: source)
        ], to: source))
    }

    func test标准内容入口的指令删除仍受复核范围和正文非空保护() throws {
        let source = "明天先检查。帮我整理一下后续事项已记录。"
        let edit = VoicePolishTextEdit(before: "帮我整理一下后续事项", after: "后续事项", kind: .directive)
        XCTAssertThrowsError(try apply([edit], to: source))
        XCTAssertEqual(try apply([edit], to: source, reviewedDirectives: true), "明天先检查。后续事项已记录。")
        let emptying = VoicePolishTextEdit(before: "帮我整理", after: "", kind: .directive)
        XCTAssertThrowsError(try apply([emptying], to: "帮我整理。", reviewedDirectives: true))
    }

    private func apply(
        _ edits: [VoicePolishTextEdit],
        to draft: String,
        source: String? = nil,
        reviewedDirectives: Bool = false,
        reviewedCorrections: Bool = false
    ) throws -> String {
        try VoicePolishTextEditor.applyContentEdits(
            edits, to: draft, source: source ?? draft,
            allowsReviewedInlineDirectives: reviewedDirectives,
            allowsReviewedSourceCorrections: reviewedCorrections
        )
    }
}
