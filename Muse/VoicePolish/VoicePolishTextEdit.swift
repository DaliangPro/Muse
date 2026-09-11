import Foundation

struct VoicePolishTextEdit: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case punctuation, stutter, word, symbol, correction, filler, directive, content
    }

    let before: String
    let after: String
    let kind: Kind
    let evidence: String?

    init(before: String, after: String, kind: Kind, evidence: String? = nil) {
        self.before = before
        self.after = after
        self.kind = kind
        self.evidence = evidence
    }
}

struct VoicePolishTextChange: Encodable, Sendable, Equatable {
    let removed: String
    let inserted: String

    /// 差异来自实际字符序列，逐块呈现给复核器；不让 Planner 先筛选有效信息。
    static func between(_ source: String, _ draft: String) -> [Self] {
        let old = Array(source)
        let new = Array(draft)
        let difference = new.difference(from: old)
        let removedIndices = Set(difference.removals.map { change -> Int in
            if case .remove(let offset, _, _) = change { return offset }
            return -1
        })
        let insertedIndices = Set(difference.insertions.map { change -> Int in
            if case .insert(let offset, _, _) = change { return offset }
            return -1
        })
        var result: [Self] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            var removed = ""
            var inserted = ""
            while oldIndex < old.count && removedIndices.contains(oldIndex) {
                removed.append(old[oldIndex]); oldIndex += 1
            }
            while newIndex < new.count && insertedIndices.contains(newIndex) {
                inserted.append(new[newIndex]); newIndex += 1
            }
            if !removed.isEmpty || !inserted.isEmpty {
                result.append(Self(removed: removed, inserted: inserted))
            }
            if oldIndex < old.count && newIndex < new.count {
                oldIndex += 1; newIndex += 1
            } else if removed.isEmpty && inserted.isEmpty {
                break
            }
        }
        return result
    }
}

enum VoicePolishTextEditError: Error, Equatable {
    case invalidResponse, ambiguousAnchor, overlappingEdits, editOutsideMode, missingEvidence
}

enum VoicePolishTextEditor {
    private struct Response: Decodable { let edits: [VoicePolishTextEdit] }
    private struct Modification {
        let range: NSRange
        let removed: String
        let inserted: String
    }
    private static let technicalMarks = Set("-_/\\`@#%")

    static func decode(_ raw: String) throws -> [VoicePolishTextEdit] {
        guard raw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["edits"] else {
            throw VoicePolishTextEditError.invalidResponse
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.edits.count <= 128 else { throw VoicePolishTextEditError.invalidResponse }
        return response.edits
    }

    /// 所有锚点一次性在不可变原稿定位，再倒序提交；失败不产生半份修改稿。
    static func apply(
        _ edits: [VoicePolishTextEdit],
        to draft: String,
        source: String,
        mode: VoicePolishQualityMode,
        allowsReviewedInlineDirectives: Bool = false
    ) throws -> String {
        var located: [Modification] = []
        for edit in edits {
            guard !edit.before.isEmpty,
                  let range = draft.range(of: edit.before, options: .literal),
                  draft.range(of: edit.before, options: .literal,
                              range: draft.unicodeScalars.index(after: range.lowerBound)..<draft.endIndex) == nil else {
                throw VoicePolishTextEditError.ambiguousAnchor
            }
            let nsRange = NSRange(range, in: draft)
            let modifications = modifications(for: edit, anchorLocation: nsRange.location)
            guard !VoicePolishCharacterSafety.containsUnsafeCharacters(edit.after) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
            if mode == .light {
                try validateLight(edit, modifications: modifications)
                if edit.kind == .directive,
                   ((!allowsReviewedInlineDirectives && nsRange.location != 0)
                        || nsRange.length == (draft as NSString).length) {
                    throw VoicePolishTextEditError.editOutsideMode
                }
            } else {
                guard mode == .standard, edit.kind == .content,
                      let evidence = edit.evidence, !evidence.isEmpty,
                      source.range(of: evidence, options: .literal) != nil else {
                    throw VoicePolishTextEditError.missingEvidence
                }
            }
            for modification in modifications {
                // 相同位置的同一插入可由相邻锚点重复描述，只提交一次。
                if modification.range.length == 0,
                   located.contains(where: {
                       $0.range == modification.range && $0.inserted == modification.inserted
                   }) { continue }
                guard !located.contains(where: { conflicts($0.range, modification.range) }) else {
                    throw VoicePolishTextEditError.overlappingEdits
                }
                located.append(modification)
            }
        }
        let result = NSMutableString(string: draft)
        for item in located.sorted(by: {
            if $0.range.location != $1.range.location { return $0.range.location > $1.range.location }
            // 同一边界先替换后插入，保证插入内容位于替换结果之前。
            return $0.range.length > $1.range.length
        }) {
            result.replaceCharacters(in: item.range, with: item.inserted)
        }
        return result as String
    }

    /// 完整锚点只负责定位和语义证据；未改变的文字不占用修改区间。
    private static func modifications(for edit: VoicePolishTextEdit, anchorLocation: Int) -> [Modification] {
        // 按 Unicode 标量对齐，与独立 Python 回放使用相同的确定性平局规则。
        let before = Array(edit.before.unicodeScalars)
        let after = Array(edit.after.unicodeScalars)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var beforeEnd = before.count
        var afterEnd = after.count
        while beforeEnd > prefix, afterEnd > prefix, before[beforeEnd - 1] == after[afterEnd - 1] {
            beforeEnd -= 1
            afterEnd -= 1
        }
        let oldCount = beforeEnd - prefix
        let newCount = afterEnd - prefix
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        // 超出局部编辑的矩阵预算时保守保留整个变化区，避免大段标准修复耗尽内存。
        if oldCount * newCount > 1_000_000 {
            removals = Set(prefix..<beforeEnd)
            insertions = Set(prefix..<afterEnd)
        } else {
            let columns = newCount + 1
            var lengths = [Int](repeating: 0, count: (oldCount + 1) * columns)
            if oldCount > 0 && newCount > 0 {
                for old in stride(from: oldCount - 1, through: 0, by: -1) {
                    for new in stride(from: newCount - 1, through: 0, by: -1) {
                        lengths[old * columns + new] = before[prefix + old] == after[prefix + new]
                            ? 1 + lengths[(old + 1) * columns + new + 1]
                            : max(lengths[(old + 1) * columns + new], lengths[old * columns + new + 1])
                    }
                }
            }
            var old = 0
            var new = 0
            while old < oldCount || new < newCount {
                if old < oldCount, new < newCount, before[prefix + old] == after[prefix + new] {
                    old += 1
                    new += 1
                } else if old < oldCount,
                          new == newCount || lengths[(old + 1) * columns + new] >= lengths[old * columns + new + 1] {
                    removals.insert(prefix + old)
                    old += 1
                } else {
                    insertions.insert(prefix + new)
                    new += 1
                }
            }
        }
        var beforeIndex = 0
        var afterIndex = 0
        var location = anchorLocation
        var result: [Modification] = []
        while beforeIndex < before.count || afterIndex < after.count {
            let start = location
            var removed = ""
            var inserted = ""
            while beforeIndex < before.count && removals.contains(beforeIndex) {
                removed.unicodeScalars.append(before[beforeIndex])
                location += String(before[beforeIndex]).utf16.count
                beforeIndex += 1
            }
            while afterIndex < after.count && insertions.contains(afterIndex) {
                inserted.unicodeScalars.append(after[afterIndex])
                afterIndex += 1
            }
            if !removed.isEmpty || !inserted.isEmpty {
                result.append(Modification(
                    range: NSRange(location: start, length: location - start),
                    removed: removed,
                    inserted: inserted
                ))
            }
            if beforeIndex < before.count && afterIndex < after.count {
                location += String(before[beforeIndex]).utf16.count
                beforeIndex += 1
                afterIndex += 1
            } else if removed.isEmpty && inserted.isEmpty {
                break
            }
        }
        return result
    }

    private static func conflicts(_ first: NSRange, _ second: NSRange) -> Bool {
        if first.length == 0 && second.length == 0 { return first.location == second.location }
        if first.length == 0 {
            return first.location > second.location && first.location < NSMaxRange(second)
        }
        if second.length == 0 {
            return second.location > first.location && second.location < NSMaxRange(first)
        }
        return NSIntersectionRange(first, second).length > 0
    }

    private static func validateLight(_ edit: VoicePolishTextEdit, modifications: [Modification]) throws {
        let before = lexicalCharacters(edit.before)
        let after = lexicalCharacters(edit.after)
        guard edit.kind != .content,
              edit.kind == .punctuation || edit.before.count <= 96,
              edit.after.filter({ $0 == "\n" }).count <= edit.before.filter({ $0 == "\n" }).count else {
            throw VoicePolishTextEditError.editOutsideMode
        }
        switch edit.kind {
        case .punctuation:
            let embeddedToken = #"[A-Za-z0-9]+(?:[.:][A-Za-z0-9]+)+"#
            let expression = try NSRegularExpression(pattern: embeddedToken)
            func tokens(_ text: String) -> [String] {
                let source = text as NSString
                return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
                    .map { source.substring(with: $0.range) }
            }
            guard before == after,
                  edit.before.filter({ technicalMarks.contains($0) }) == edit.after.filter({ technicalMarks.contains($0) }),
                  tokens(edit.before) == tokens(edit.after) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .stutter:
            guard isAdjacentRepetitionRemoval(before: before, after: after) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .word:
            let difference = after.difference(from: before)
            let changes = VoicePolishTextChange.between(String(before), String(after))
            guard (0...8).contains(difference.removals.count),
                  (1...8).contains(difference.insertions.count), changes.count == 1,
                  edit.before.filter({ technicalMarks.contains($0) }) == edit.after.filter({ technicalMarks.contains($0) }) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .symbol:
            // 只恢复明确口述的技术符号；不把自然语言的“点”全局改成小数点。
            var projected = edit.before
            for (spoken, symbol) in [("双横线", "--"), ("短横线", "-"),
                                     ("反斜杠", "\\"), ("斜杠", "/"), ("下划线", "_")] {
                projected = projected.replacingOccurrences(of: spoken, with: symbol)
            }
            projected = projected.replacingOccurrences(
                of: #"(?<=[A-Za-z0-9_])点(?=[A-Za-z0-9_])"#,
                with: ".", options: .regularExpression
            )
            guard projected != edit.before,
                  projected.filter({ !$0.isWhitespace }) == edit.after.filter({ !$0.isWhitespace }) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .correction:
            let cues = ["不对", "说错", "改成", "改为", "应该是", "我改一下", "不用写", "不要写", "actually", "i mean", "scratch that"]
            guard cues.contains(where: edit.before.lowercased().contains),
                  isSubsequence(after, of: before) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .filler:
            let removed = modifications.map(\.removed).joined()
            guard modifications.allSatisfy({ $0.inserted.isEmpty }),
                  !removed.isEmpty, removed.count <= 6,
                  Set(removed).isSubset(of: Set("嗯呃额啊唔")) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .directive:
            // 仅允许移除很短的当前编辑前缀；内嵌任务与正文没有该删除权限。
            guard edit.before.count <= 32, edit.after.isEmpty,
                  edit.before.last.map({ "：:，,。.".contains($0) }) == true else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .content:
            throw VoicePolishTextEditError.editOutsideMode
        }
    }

    private static func lexicalCharacters(_ text: String) -> [Character] {
        let characters = Array(text)
        func asciiWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        return characters.enumerated().compactMap { index, character in
            if technicalMarks.contains(character) { return character }
            if (character == "." || character == ":"), index > 0, index + 1 < characters.count,
               asciiWord(characters[index - 1]), asciiWord(characters[index + 1]) {
                return character
            }
            return character.isWhitespace || character.isPunctuation ? nil : character
        }
    }

    private static func isAdjacentRepetitionRemoval(before: [Character], after: [Character]) -> Bool {
        guard !after.isEmpty, after.count < before.count else { return false }
        var visited: Set<Int> = []
        func matches(_ old: Int, _ new: Int) -> Bool {
            if old == before.count || new == after.count {
                return old == before.count && new == after.count
            }
            let key = old * (after.count + 1) + new
            guard visited.insert(key).inserted else { return false }
            if before[old] == after[new], matches(old + 1, new + 1) { return true }
            let maximumWidth = min((before.count - old) / 2, after.count - new)
            guard maximumWidth > 0 else { return false }
            for width in 1...maximumWidth {
                let unit = Array(after[new..<(new + width)])
                guard Array(before[old..<(old + width)]) == unit else { continue }
                var end = old + width
                while end + width <= before.count && Array(before[end..<(end + width)]) == unit {
                    end += width
                    if matches(end, new + width) { return true }
                }
            }
            return false
        }
        return matches(0, 0)
    }

    private static func isSubsequence(_ candidate: [Character], of source: [Character]) -> Bool {
        var index = 0
        for character in source where index < candidate.count {
            if character == candidate[index] { index += 1 }
        }
        return index == candidate.count
    }
}
