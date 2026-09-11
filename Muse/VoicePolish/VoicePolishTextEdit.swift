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

    struct ReviewFocus: Encodable, Sendable, Equatable {
        let changeIndex: Int
        let sourceStart: Int
        let sourceEnd: Int
        let draftStart: Int
        let draftEnd: Int
        let sourceContext: String
        let draftContext: String
    }

    struct ComparisonEvidence: Sendable, Equatable {
        let changes: [VoicePolishTextChange]
        let reviewFocus: [ReviewFocus]
        let contentChangeCount: Int
    }

    private struct LocatedChange {
        let change: VoicePolishTextChange
        let sourceRange: Range<Int>
        let draftRange: Range<Int>
    }

    // 仅用于组织复核注意力；保守保留技术符号和 emoji，不据此授予编辑权限。
    private static let layoutCharacters = Set("，。！？；：、")

    /// 差异来自实际字符序列，逐块呈现给复核器；不让 Planner 先筛选有效信息。
    static func between(_ source: String, _ draft: String) -> [Self] {
        locatedChanges(Array(source), Array(draft)).map(\.change)
    }

    /// 只运行一次 diff；保留所有变化，额外突出最多 16 处含内容变化的实际位置。
    static func comparisonEvidence(_ source: String, _ draft: String) -> ComparisonEvidence {
        let old = Array(source)
        let new = Array(draft)
        let located = locatedChanges(old, new)
        let priorities = located.enumerated().compactMap { index, item -> (index: Int, group: Int, amount: Int)? in
            let removedCount = contentCount(item.change.removed)
            let insertedCount = contentCount(item.change.inserted)
            guard removedCount + insertedCount > 0 else { return nil }
            return (index, removedCount > 0 ? 0 : 1, removedCount + insertedCount)
        }.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            if $0.amount != $1.amount { return $0.amount > $1.amount }
            return $0.index < $1.index
        }
        let focus = priorities.prefix(16).map { priority in
            let item = located[priority.index]
            return ReviewFocus(
                changeIndex: priority.index,
                sourceStart: item.sourceRange.lowerBound, sourceEnd: item.sourceRange.upperBound,
                draftStart: item.draftRange.lowerBound, draftEnd: item.draftRange.upperBound,
                sourceContext: context(old, around: item.sourceRange),
                draftContext: context(new, around: item.draftRange)
            )
        }
        return ComparisonEvidence(changes: located.map(\.change), reviewFocus: focus,
                                  contentChangeCount: priorities.count)
    }

    private static func contentCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !layoutCharacters.contains($0) }.count
    }

    private static func context(_ text: [Character], around range: Range<Int>) -> String {
        String(text[max(0, range.lowerBound - 20)..<min(text.count, range.upperBound + 20)])
    }

    /// 沿用旧差异与消费顺序，只记录消费前后的 Character 半开范围。
    private static func locatedChanges(_ old: [Character], _ new: [Character]) -> [LocatedChange] {
        let difference = new.difference(from: old)
        let removedIndices = Set(difference.removals.map { change -> Int in
            if case .remove(let offset, _, _) = change { return offset }
            return -1
        })
        let insertedIndices = Set(difference.insertions.map { change -> Int in
            if case .insert(let offset, _, _) = change { return offset }
            return -1
        })
        var result: [LocatedChange] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            let sourceStart = oldIndex
            let draftStart = newIndex
            var removed = ""
            var inserted = ""
            while oldIndex < old.count && removedIndices.contains(oldIndex) {
                removed.append(old[oldIndex]); oldIndex += 1
            }
            while newIndex < new.count && insertedIndices.contains(newIndex) {
                inserted.append(new[newIndex]); newIndex += 1
            }
            if !removed.isEmpty || !inserted.isEmpty {
                result.append(LocatedChange(change: Self(removed: removed, inserted: inserted),
                                            sourceRange: sourceStart..<oldIndex,
                                            draftRange: draftStart..<newIndex))
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
    /// 编辑权限与用户选择的产品档位分离；标准的新内容阶段只能使用局部编辑。
    private enum EditPolicy {
        case localContent, legacyStandardContent, disabled
    }
    private struct Modification {
        let range: NSRange
        let removed: String
        let inserted: String
    }
    private static let technicalMarks = Set("-_/\\`@#%")
    private static let clockExpression = try? NSRegularExpression(pattern: #"(?:[01]?[0-9]|2[0-3]):[0-5][0-9]"#)

    /// 是否免于语义核对取决于完整实际变化，模型自报 kind 不授予免审权限。
    static func requiresSemanticReview(_ edits: [VoicePolishTextEdit], in draft: String? = nil) -> Bool {
        guard !edits.contains(where: { $0.kind == .content || !isMechanicalEdit($0, in: draft) }) else { return true }
        guard let draft else { return false }
        let projected = edits.map { edit in
            VoicePolishTextEdit(before: edit.before, after: mechanicalProjection(edit, in: draft) ?? edit.after, kind: edit.kind)
        }
        guard let expected = applyingProjections(projected, to: draft),
              let actual = applyingProjections(edits, to: draft) else { return true }
        return !punctuationPreservesTechnicalTokens(expected, actual)
    }

    /// 完整候选只作为唯一锚点；严格免审证明不授予口吃、唔/呃等待核对删除权限。
    /// 不推断 kind 或 evidence，也不挑选部分修改交付。
    static func applyingUnreviewedMechanicalChanges(from source: String, to target: String) throws -> String {
        let edit = VoicePolishTextEdit(before: source, after: target, kind: .punctuation)
        guard !requiresSemanticReview([edit], in: source) else {
            throw VoicePolishTextEditError.editOutsideMode
        }
        let output = try apply([edit], to: source, source: source, mode: .light)
        guard output.utf8.elementsEqual(target.utf8) else {
            throw VoicePolishTextEditError.editOutsideMode
        }
        return output
    }

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
        allowsReviewedInlineDirectives: Bool = false,
        allowsReviewedSourceCorrections: Bool = false
    ) throws -> String {
        let policy: EditPolicy
        switch mode {
        case .light:
            // 轻度保留任务原话。即使被标成机械变化或已经复核，也不授予代写删除权限。
            guard !edits.contains(where: { $0.kind == .directive || $0.kind == .content }) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
            policy = .localContent
        case .standard: policy = .legacyStandardContent
        case .automatic, .fast, .balanced, .quality: policy = .disabled
        }
        return try apply(edits, to: draft, source: source, policy: policy,
                         allowsReviewedInlineDirectives: allowsReviewedInlineDirectives,
                         allowsReviewedSourceCorrections: allowsReviewedSourceCorrections)
    }

    /// 标准润色的内容修正入口：局部纠错后另做完整片段拼装，不授予自由正文重写权限。
    static func applyContentEdits(
        _ edits: [VoicePolishTextEdit],
        to draft: String,
        source: String,
        allowsReviewedInlineDirectives: Bool = false,
        allowsReviewedSourceCorrections: Bool = false
    ) throws -> String {
        try apply(edits, to: draft, source: source, policy: .localContent,
                  allowsReviewedInlineDirectives: allowsReviewedInlineDirectives,
                  allowsReviewedSourceCorrections: allowsReviewedSourceCorrections)
    }

    private static func apply(
        _ edits: [VoicePolishTextEdit],
        to draft: String,
        source: String,
        policy: EditPolicy,
        allowsReviewedInlineDirectives: Bool,
        allowsReviewedSourceCorrections: Bool
    ) throws -> String {
        var located: [Modification] = []
        var projectedEdits: [VoicePolishTextEdit] = []
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
            if policy == .localContent {
                try validateLocalContent(edit, modifications: modifications, source: source,
                                         draft: draft,
                                         allowsReviewedDirectives: allowsReviewedInlineDirectives,
                                         allowsReviewedSourceCorrections: allowsReviewedSourceCorrections)
                if edit.kind == .directive, !isMechanicalEdit(edit, in: draft, allowsReviewedChanges: true),
                   ((!allowsReviewedInlineDirectives && nsRange.location != 0)
                        || (!allowsReviewedInlineDirectives && nsRange.length == (draft as NSString).length)) {
                    throw VoicePolishTextEditError.editOutsideMode
                }
            } else {
                guard policy == .legacyStandardContent, edit.kind == .content,
                      let evidence = edit.evidence, !evidence.isEmpty,
                      source.range(of: evidence, options: .literal) != nil else {
                    throw VoicePolishTextEditError.missingEvidence
                }
            }
            if policy == .localContent {
                projectedEdits.append(.init(before: edit.before,
                    after: mechanicalProjection(edit, in: draft, allowsReviewedChanges: true) ?? edit.after, kind: edit.kind))
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
        if policy == .localContent {
            guard let expected = applyingProjections(projectedEdits, to: draft),
                  punctuationPreservesTechnicalTokens(expected, result as String) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        }
        if policy == .localContent, edits.contains(where: { $0.kind == .directive }),
           lexicalCharacters(result as String).isEmpty {
            throw VoicePolishTextEditError.editOutsideMode
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

    /// 整批投影也使用同一原稿和冲突规则，防止两个各自保留空格的补丁合并后拆坏技术词。
    private static func applyingProjections(_ edits: [VoicePolishTextEdit], to draft: String) -> String? {
        var located: [Modification] = []
        for edit in edits {
            guard !edit.before.isEmpty, let range = draft.range(of: edit.before, options: .literal),
                  draft.range(of: edit.before, options: .literal,
                              range: draft.unicodeScalars.index(after: range.lowerBound)..<draft.endIndex) == nil else { return nil }
            for change in modifications(for: edit, anchorLocation: NSRange(range, in: draft).location) {
                if change.range.length == 0, located.contains(where: { $0.range == change.range && $0.inserted == change.inserted }) { continue }
                guard !located.contains(where: { conflicts($0.range, change.range) }) else { return nil }
                located.append(change)
            }
        }
        let output = NSMutableString(string: draft)
        for change in located.sorted(by: {
            $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location > $1.range.location
        }) { output.replaceCharacters(in: change.range, with: change.inserted) }
        return output as String
    }

    private static func validateLocalContent(
        _ edit: VoicePolishTextEdit,
        modifications: [Modification],
        source: String = "",
        draft: String? = nil,
        allowsReviewedDirectives: Bool = false,
        allowsReviewedSourceCorrections: Bool = false
    ) throws {
        let before = lexicalCharacters(edit.before)
        let after = lexicalCharacters(edit.after)
        let beforeParagraphs = edit.before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { lexicalCharacters(String($0)) }
        let afterParagraphs = edit.after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { lexicalCharacters(String($0)) }
        let paragraphPairs = Array(zip(beforeParagraphs, afterParagraphs))
        guard edit.kind != .content,
              edit.before.filter(\.isNewline) == edit.after.filter(\.isNewline),
              beforeParagraphs.count == afterParagraphs.count,
              modifications.allSatisfy({
                  !$0.removed.contains(where: \.isNewline) && !$0.inserted.contains(where: \.isNewline)
              }),
              edit.after.filter({ $0 == "\n" }).count <= edit.before.filter({ $0 == "\n" }).count else {
            throw VoicePolishTextEditError.editOutsideMode
        }
        if isMechanicalEdit(edit, in: draft, allowsReviewedChanges: true) { return }
        guard edit.kind == .punctuation || edit.kind == .directive || edit.before.count <= 96 else {
            throw VoicePolishTextEditError.editOutsideMode
        }
        switch edit.kind {
        case .punctuation:
            throw VoicePolishTextEditError.editOutsideMode
        case .stutter:
            guard isAdjacentRepetitionRemoval(before: before, after: after),
                  paragraphPairs.allSatisfy({ $0.0 == $0.1 || isAdjacentRepetitionRemoval(before: $0.0, after: $0.1) }) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .word:
            let difference = after.difference(from: before)
            let changes = VoicePolishTextChange.between(String(before), String(after))
            guard (0...8).contains(difference.removals.count),
                  (1...8).contains(difference.insertions.count), changes.count == 1,
                  paragraphPairs.filter({ $0.0 != $0.1 }).count == 1,
                  edit.before.filter({ technicalMarks.contains($0) }) == edit.after.filter({ technicalMarks.contains($0) }) else {
                throw VoicePolishTextEditError.editOutsideMode
            }
        case .symbol:
            throw VoicePolishTextEditError.editOutsideMode
        case .correction:
            let cues = ["不对", "说错", "改成", "改为", "改由", "应该是", "我改一下", "不用写", "不要写", "actually", "i mean", "scratch that"]
            let changes = Self.modifications(
                for: .init(before: String(before), after: String(after), kind: .correction),
                anchorLocation: 0
            )
            // 近邻改口和远处有据改口共享实际修改预算；子序列关系不授予整段删减权限。
            // 预算只约束编辑幅度，不能据此证明被删内容在语义上无效。
            guard changes.reduce(0, { $0 + $1.removed.unicodeScalars.count }) <= 32,
                  changes.reduce(0, { $0 + $1.inserted.unicodeScalars.count }) <= 8 else {
                throw VoicePolishTextEditError.editOutsideMode
            }
            let preservesTechnicalContent = technicalContent(in: before) == technicalContent(in: after)
            if cues.contains(where: edit.before.lowercased().contains), isSubsequence(after, of: before),
               paragraphPairs.allSatisfy({ isSubsequence($0.1, of: $0.0) }) {
                guard preservesTechnicalContent || preservesTechnicalContentByRemovingClocks(edit, in: draft) else {
                    throw VoicePolishTextEditError.editOutsideMode
                }
                break
            }
            guard preservesTechnicalContent, allowsReviewedSourceCorrections,
                  let evidence = edit.evidence, !evidence.isEmpty, evidence.unicodeScalars.count <= 192,
                  source.range(of: evidence, options: .literal) != nil,
                  sourceContainsPunctuationEquivalentAnchor(edit.before, in: source),
                  cues.contains(where: evidence.lowercased().contains),
                  edit.before.unicodeScalars.count <= 96,
                  paragraphPairs.filter({ $0.0 != $0.1 }).count == 1 else {
                throw VoicePolishTextEditError.editOutsideMode
            }
            guard changes.count == 1, let change = changes.first,
                  change.inserted.isEmpty || evidence.range(of: change.inserted, options: .literal) != nil else {
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
            if allowsReviewedDirectives {
                // 未变后缀仅帮助定位；删除权限只覆盖实际连续短片段，必须另经语义核对。
                guard modifications.count == 1, let change = modifications.first,
                      change.inserted.isEmpty, !change.removed.isEmpty, change.removed.count <= 32 else {
                    throw VoicePolishTextEditError.editOutsideMode
                }
            } else {
                guard edit.before.count <= 32, edit.after.isEmpty,
                      edit.before.last.map({ "：:，,。.".contains($0) }) == true else {
                    throw VoicePolishTextEditError.editOutsideMode
                }
            }
        case .content:
            throw VoicePolishTextEditError.editOutsideMode
        }
    }

    private static func sourceContainsPunctuationEquivalentAnchor(_ anchor: String, in source: String) -> Bool {
        if source.range(of: anchor, options: .literal) != nil { return true }
        let characters = Array(source)
        let indices = lexicalIndices(characters)
        let words = indices.map { characters[$0] }
        let wanted = lexicalCharacters(anchor)
        guard !wanted.isEmpty, wanted.count <= words.count else { return false }
        for start in 0...(words.count - wanted.count) {
            guard Array(words[start..<(start + wanted.count)]) == wanted else { continue }
            let candidate = String(characters[indices[start]...indices[start + wanted.count - 1]])
            if candidate.filter(\.isNewline) == anchor.filter(\.isNewline),
               punctuationPreservesTechnicalTokens(candidate, anchor) { return true }
        }
        return false
    }

    private static func isMechanicalEdit(_ edit: VoicePolishTextEdit, in draft: String? = nil,
                                         allowsReviewedChanges: Bool = false) -> Bool {
        mechanicalProjection(edit, in: draft, allowsReviewedChanges: allowsReviewedChanges) != nil
    }

    private static func mechanicalProjection(_ edit: VoicePolishTextEdit, in draft: String? = nil,
                                         allowsReviewedChanges: Bool = false) -> String? {
        let context = draft ?? edit.before
        guard !edit.before.isEmpty, let anchor = context.range(of: edit.before, options: .literal),
              context.range(of: edit.before, options: .literal,
                            range: context.unicodeScalars.index(after: anchor.lowerBound)..<context.endIndex) == nil,
              edit.before.filter(\.isNewline) == edit.after.filter(\.isNewline),
              !VoicePolishCharacterSafety.containsUnsafeCharacters(edit.after),
              modifications(for: edit, anchorLocation: 0).allSatisfy({
                  !$0.removed.contains(where: \.isNewline) && !$0.inserted.contains(where: \.isNewline)
              }) else { return nil }
        var symbolProjection = edit.before
        for (spoken, symbol) in [("双横线", "--"), ("短横线", "-"), ("反斜杠", "\\"),
                                 ("斜杠", "/"), ("下划线", "_")] {
            symbolProjection = symbolProjection.replacingOccurrences(of: spoken, with: symbol)
        }
        symbolProjection = symbolProjection.replacingOccurrences(
            of: #"(?<=[A-Za-z0-9_])点(?=[A-Za-z0-9_])"#, with: ".", options: .regularExpression
        )
        let permissions = fillerPermissions(in: context, anchor: NSRange(anchor, in: context))
        let rawParagraphs = edit.before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let newParagraphs = edit.after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for candidate in [edit.before, symbolProjection] {
            let oldParagraphs = candidate.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard oldParagraphs.count == newParagraphs.count else { continue }
            var fillers = 0
            var valid = true
            var permissionOffset = 0
            var projections: [String] = []
            for (index, pair) in zip(oldParagraphs, newParagraphs).enumerated() {
                let (old, new) = pair
                let count = rawParagraphs[index].filter { "嗯呃额啊唔".contains($0) }.count
                guard permissionOffset + count <= permissions.count else { valid = false; break }
                guard let projection = mechanicalParagraph(String(old), matching: String(new),
                                                           fillers: &fillers,
                                                           permissions: Array(permissions[permissionOffset..<(permissionOffset + count)]),
                                                           allowsReviewedChanges: allowsReviewedChanges),
                      punctuationPreservesTechnicalTokens(projection, String(new)) else {
                    valid = false
                    break
                }
                projections.append(projection)
                permissionOffset += count
            }
            if valid {
                let separators = candidate.filter(\.isNewline).map(String.init)
                let projection = projections.enumerated().map { index, part in
                    part + (index < separators.count ? separators[index] : "")
                }.joined()
                // 局部证明放回真实稿再核对技术 token，覆盖锚点边缘的拆词与并词。
                let expected = context.replacingCharacters(in: anchor, with: projection)
                let actual = context.replacingCharacters(in: anchor, with: edit.after)
                if punctuationPreservesTechnicalTokens(expected, actual) { return projection }
            }
        }
        return nil
    }

    /// 返回原段落中被证明保留的字符，既不生成词语，也不跨原段落寻找删除证据。
    private static func mechanicalParagraph(_ before: String, matching after: String,
                                            fillers: inout Int, permissions: [Bool], allowsReviewedChanges: Bool) -> String? {
        let characters = Array(before)
        let indices = lexicalIndices(characters)
        let old = indices.map { characters[$0] }
        let new = lexicalCharacters(after)
        // 首条匹配路径已完整相等；保留原标点，仍由外层检查目标的段落和技术字符。
        if old == new { return before }
        let fillerCharacters = Set("嗯呃额啊唔")
        var allowedFillers: Set<Int> = []
        var ordinal = 0
        for (index, character) in characters.enumerated() where fillerCharacters.contains(character) {
            if ordinal < permissions.count, permissions[ordinal] { allowedFillers.insert(index) }
            ordinal += 1
        }
        let numberCharacters = Set("零〇一二三四五六七八九十百千万亿两")
        let allowsStutter = allowsReviewedChanges && before.count <= 96
        struct State: Hashable {
            let i: Int
            let j: Int
            let used: Int
        }
        struct Step {
            let state: State
            let kept: Range<Int>
        }
        struct Frame {
            let state: State
            let kept: Range<Int>
            let steps: [Step]
            var next = 0
        }
        func steps(from state: State) -> [Step] {
            let (i, j, used) = (state.i, state.j, state.used)
            var result: [Step] = []
            if i < old.count, j < new.count, old[i] == new[j] {
                result.append(Step(state: State(i: i + 1, j: j + 1, used: used), kept: i..<(i + 1)))
            }
            // 唔、呃也能承载否定或实词义；只允许形成待核对稿，不能据停顿声形状免审。
            if i < old.count, used < 6, fillerCharacters.contains(old[i]), allowedFillers.contains(indices[i]),
               (allowsReviewedChanges || !Set("唔呃").contains(old[i])) {
                result.append(Step(state: State(i: i + 1, j: j, used: used + 1), kept: i..<i))
            }
            // 数字、英文技术词及标点隔开的有意重复不自动解释为口吃。
            let maximumWidth = min((old.count - i) / 2, new.count - j)
            if allowsStutter, maximumWidth > 0 {
                for width in 1...maximumWidth {
                    let unit = Array(old[i..<(i + width)])
                    guard unit == Array(new[j..<(j + width)]),
                          unit.allSatisfy({ $0.isLetter && !$0.isASCII && !numberCharacters.contains($0) }) else { continue }
                    var end = i + width
                    while end + width <= old.count, Array(old[end..<(end + width)]) == unit {
                        end += width
                        let raw = characters[indices[i]...indices[end - 1]]
                        guard raw.allSatisfy({ !$0.isPunctuation }) else { break }
                        result.append(Step(state: State(i: end, j: j + width, used: used), kept: i..<(i + width)))
                    }
                }
            }
            return result
        }
        // 显式深度优先栈保持原先“保留、停顿声、口吃”的分支顺序和失败缓存。
        // 长稿的逐字保留不再占用调用栈；成功后一次重建保留位置，避免逐层复制。
        let initial = State(i: 0, j: 0, used: fillers)
        var stack = [Frame(state: initial, kept: 0..<0, steps: steps(from: initial))]
        var failed: Set<State> = []
        var keptIndices: [Int]?
        while let frame = stack.last {
            if frame.state.i == old.count && frame.state.j == new.count {
                keptIndices = stack.flatMap { Array($0.kept) }
                fillers = frame.state.used
                break
            }
            guard frame.next < frame.steps.count else {
                failed.insert(frame.state)
                stack.removeLast()
                continue
            }
            let step = frame.steps[frame.next]
            stack[stack.count - 1].next += 1
            guard !failed.contains(step.state) else { continue }
            stack.append(Frame(state: step.state, kept: step.kept, steps: steps(from: step.state)))
        }
        guard let keptIndices else { return nil }
        let kept = Set(keptIndices.map { indices[$0] })
        let lexical = Set(indices)
        return String(characters.enumerated().compactMap { lexical.contains($0.offset) && !kept.contains($0.offset) ? nil : $0.element })
    }

    private static func fillerPermissions(in text: String, anchor: NSRange) -> [Bool] {
        let characters = Array(text)
        let fillers = Set("嗯呃额啊唔")
        var location = 0
        var result: [Bool] = []
        for (index, character) in characters.enumerated() {
            defer { location += String(character).utf16.count }
            guard fillers.contains(character), NSLocationInRange(location, anchor) else { continue }
            var start = index
            var end = index + 1
            while start > 0, fillers.contains(characters[start - 1]) { start -= 1 }
            while end < characters.count, fillers.contains(characters[end]) { end += 1 }
            let leftBoundary = start == 0 || characters[start - 1].isWhitespace || characters[start - 1].isPunctuation
            let rightBoundary = end == characters.count || characters[end].isWhitespace || characters[end].isPunctuation
            result.append(leftBoundary && (!characters[start..<end].contains("额") || rightBoundary))
        }
        return result
    }

    private static func punctuationPreservesTechnicalTokens(_ before: String, _ after: String) -> Bool {
        func tokens(_ text: String, _ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let source = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }
        }
        return lexicalCharacters(before) == lexicalCharacters(after)
            && before.filter({ technicalMarks.contains($0) }) == after.filter({ technicalMarks.contains($0) })
            && tokens(before, #"[A-Za-z0-9]+(?:[.:][A-Za-z0-9]+)+"#) == tokens(after, #"[A-Za-z0-9]+(?:[.:][A-Za-z0-9]+)+"#)
            && tokens(before, #"[A-Za-z0-9_]+"#) == tokens(after, #"[A-Za-z0-9_]+"#)
            && tokens(before, #"(?<![A-Za-z0-9_])\.[A-Za-z0-9_][A-Za-z0-9_.-]*"#)
                == tokens(after, #"(?<![A-Za-z0-9_])\.[A-Za-z0-9_][A-Za-z0-9_.-]*"#)
    }

    private static func technicalContent(in lexical: [Character]) -> String {
        String(String.UnicodeScalarView(String(lexical).unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return false
            default:
                return true
            }
        }))
    }

    /// 仅为近邻改口豁免完整旧钟面的冒号；不允许拼出新时间、拆掉技术 token 或清空全部钟面。
    private static func preservesTechnicalContentByRemovingClocks(_ edit: VoicePolishTextEdit, in draft: String?) -> Bool {
        func isBoundary(_ character: Character) -> Bool {
            character.isWhitespace || "，。！？；、（）“”‘’(),;!?'\"".contains(character)
                || String(character).range(of: #"^\p{Han}$"#, options: .regularExpression) != nil
        }
        func parts(_ text: String) -> (clocks: [String], remainder: String)? {
            guard let clockExpression else { return nil }
            let boundaries = Set(text.indices).union([text.endIndex])
            let matches = clockExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
                guard let range = Range(match.range, in: text), boundaries.contains(range.lowerBound),
                      boundaries.contains(range.upperBound) else { return false }
                let left = range.lowerBound == text.startIndex || isBoundary(text[text.index(before: range.lowerBound)])
                let right = range.upperBound == text.endIndex || isBoundary(text[range.upperBound])
                return left && right
            }
            let original = text as NSString
            let remainder = NSMutableString(string: text)
            for match in matches.reversed() { remainder.replaceCharacters(in: match.range, with: "") }
            return (matches.map { original.substring(with: $0.range) }, remainder as String)
        }
        // 使用真实稿邻接，不能通过把锚点裁到冒号或路径中间来伪造完整时间边界。
        guard let draft, let range = draft.range(of: edit.before, options: .literal),
              draft.range(of: edit.before, options: .literal,
                          range: draft.unicodeScalars.index(after: range.lowerBound)..<draft.endIndex) == nil,
              let old = parts(draft), let new = parts(draft.replacingCharacters(in: range, with: edit.after)), !new.clocks.isEmpty,
              new.clocks.count < old.clocks.count else { return false }
        var index = 0
        for clock in old.clocks where index < new.clocks.count {
            if clock == new.clocks[index] { index += 1 }
        }
        let oldRemainder = lexicalCharacters(old.remainder)
        let newRemainder = lexicalCharacters(new.remainder)
        return index == new.clocks.count && isSubsequence(newRemainder, of: oldRemainder)
            && technicalContent(in: oldRemainder) == technicalContent(in: newRemainder)
    }

    private static func lexicalCharacters(_ text: String) -> [Character] {
        let characters = Array(text)
        return lexicalIndices(characters).map { characters[$0] }
    }

    private static func lexicalIndices(_ characters: [Character]) -> [Int] {
        func asciiWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        return characters.enumerated().compactMap { index, character in
            if technicalMarks.contains(character) { return index }
            if (character == "." || character == ":"), index > 0, index + 1 < characters.count,
               asciiWord(characters[index - 1]), asciiWord(characters[index + 1]) {
                return index
            }
            return character.isWhitespace || character.isPunctuation ? nil : index
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
