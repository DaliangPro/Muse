import Foundation

enum VoicePolishEditingReviewError: Error {
    case invalidResponse
    case missingSourceQuote
}

/// 复核先明确交付类型，只摘取当前编辑要求；不复制整篇正文角色清单。
/// 交付类型和摘录都不是删除权限，实际补丁仍须经过档位与事实校验。
struct VoicePolishEditingReview: Sendable {
    enum Delivery: String, Sendable {
        case directReply = "direct_reply"
        case aiPrompt = "ai_prompt"
        case delegatedTask = "delegated_task"
        case otherOrUncertain = "other_or_uncertain"
    }

    let delivery: Delivery
    let editorSpans: [String]
    let edits: [VoicePolishTextEdit]
    let layout: [VoicePolishStructurePlan.Block]?

    /// 轻度只复核局部纠错，不接收标准模式的交付类型、编辑摘录或布局字段。
    static func decodeLightEdits(_ raw: String) throws -> [VoicePolishTextEdit] {
        do {
            return try VoicePolishTextEditor.decode(raw)
        } catch {
            throw VoicePolishEditingReviewError.invalidResponse
        }
    }

    /// 自我纠错线索只触发复核，不授予删除任务原话、禁令或其他正文的权限。
    static func hasLightSourceReviewRisk(_ source: String) -> Bool {
        let lowered = source.lowercased()
        let cues = ["我补", "等一下", "不对", "说错", "改成", "改为", "改由", "我改一下",
                    "actually", "i mean", "scratch that"]
        return cues.contains(where: lowered.contains)
    }

    static func decode(
        _ raw: String, source: String,
        structureSegments: [VoicePolishStructurePlan.Segment]? = nil
    ) throws -> Self {
        let expectedKeys: Set<String> = structureSegments == nil
            ? ["delivery", "editor_spans", "edits"] : ["delivery", "editor_spans", "edits", "layout"]
        guard raw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == expectedKeys,
              let rawDelivery = object["delivery"] as? String,
              let delivery = Delivery(rawValue: rawDelivery),
              let spans = object["editor_spans"] as? [String], spans.count <= 64 else {
            throw VoicePolishEditingReviewError.invalidResponse
        }
        var seen: Set<String> = []
        for quote in spans {
            guard !quote.isEmpty, quote.count <= 192,
                  !comparisonText(quote).isEmpty,
                  seen.insert(quote).inserted,
                  let range = source.range(of: quote, options: .literal),
                  source.range(of: quote, options: .literal,
                               range: source.unicodeScalars.index(after: range.lowerBound)..<source.endIndex) == nil else {
                throw VoicePolishEditingReviewError.missingSourceQuote
            }
        }
        let editData = try JSONSerialization.data(withJSONObject: ["edits": object["edits"] as Any])
        do {
            let edits = try VoicePolishTextEditor.decode(String(decoding: editData, as: UTF8.self))
            var layout: [VoicePolishStructurePlan.Block]?
            if let structureSegments {
                if edits.isEmpty {
                    layout = try VoicePolishStructurePlan.decodeLayout(
                        from: object["layout"] as Any, segments: structureSegments
                    )
                } else {
                    // 内容修复改变片段边界，旧稿布局不能沿用到修复稿。
                    guard let pending = object["layout"] as? [Any], pending.isEmpty else {
                        throw VoicePolishEditingReviewError.invalidResponse
                    }
                }
            }
            return Self(delivery: delivery, editorSpans: spans, edits: edits, layout: layout)
        } catch {
            throw VoicePolishEditingReviewError.invalidResponse
        }
    }

    /// 只拦截已经判为当前编辑要求、却仍逐字留在正文的情况，不据标签自动删字。
    func containsUnappliedEditorInstruction(in draft: String) -> Bool {
        let text = Self.comparisonText(draft)
        return editorSpans.contains { text.contains(Self.comparisonText($0)) }
    }

    /// 这里只决定是否多核对一次；命中词不会决定谁是收件人，也不会直接删除内容。
    static func hasSourceReviewRisk(_ source: String) -> Bool {
        let lowered = source.lowercased()
        let cues = ["帮我", "替我", "你帮", "整理成", "润色", "改写", "提示词", "prompt",
                    "我补", "等一下", "不对", "说错", "改成", "改为", "改由", "我改一下",
                    "不用写", "不要写", "别写", "先别", "只整理", "actually", "i mean", "scratch that"]
        if cues.contains(where: lowered.contains) { return true }
        return lowered.range(of: #"(?:给|跟)[^。！？\n]{0,16}(?:回|说)(?:一下|一条|一声)"#,
                             options: .regularExpression) != nil
    }

    private static func comparisonText(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !$0.isPunctuation })
    }
}
