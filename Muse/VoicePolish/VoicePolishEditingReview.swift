import Foundation

/// 复核先说明原文中指令面向谁，再决定实际稿是否需要修改。
/// 角色标签不是删除权限；所有补丁仍须通过当前模式的编辑与事实校验。
struct VoicePolishEditingReview: Sendable {
    struct SourceRole: Decodable, Sendable {
        enum Role: String, Decodable, Sendable {
            case currentEditor = "current_editor"
            case recipientContent = "recipient_content"
            case uncertain
        }
        let quote: String
        let role: Role
        let targetEvidence: String
    }

    let sourceRoles: [SourceRole]
    let edits: [VoicePolishTextEdit]

    static func decode(_ raw: String, source: String) throws -> Self {
        guard raw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["source_roles", "edits"],
              let roles = object["source_roles"] as? [[String: Any]], roles.count <= 64,
              roles.allSatisfy({ Set($0.keys) == ["quote", "role", "target_evidence"] }) else {
            throw VoicePolishTextEditError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode([SourceRole].self, from: JSONSerialization.data(withJSONObject: roles))
        var seen: Set<String> = []
        for item in decoded {
            guard !item.quote.isEmpty, item.quote.count <= 192,
                  !item.targetEvidence.isEmpty, item.targetEvidence.count <= 192,
                  !comparisonText(item.quote).isEmpty,
                  seen.insert(item.quote).inserted,
                  let range = source.range(of: item.quote, options: .literal),
                  source.range(of: item.quote, options: .literal,
                               range: source.unicodeScalars.index(after: range.lowerBound)..<source.endIndex) == nil,
                  source.range(of: item.targetEvidence, options: .literal) != nil else {
                throw VoicePolishTextEditError.missingEvidence
            }
        }
        let editData = try JSONSerialization.data(withJSONObject: ["edits": object["edits"] as Any])
        return Self(sourceRoles: decoded,
                    edits: try VoicePolishTextEditor.decode(String(decoding: editData, as: UTF8.self)))
    }

    /// 只拦截已经判为当前编辑要求、却仍逐字留在正文的情况，不据标签自动删字。
    func containsUnappliedEditorInstruction(in draft: String) -> Bool {
        let text = Self.comparisonText(draft)
        return sourceRoles.contains {
            $0.role == .currentEditor && text.contains(Self.comparisonText($0.quote))
        }
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
