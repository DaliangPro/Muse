import Foundation

enum EntityResolver {
    static let similarityThreshold = 0.88
    static let confidenceMargin = 0.08
    private static let englishPhoneticThreshold = 0.94
    private static let chinesePinyinThreshold = 0.94

    private struct Candidate: Sendable {
        let alias: String
        let canonical: String
        let source: EntityCandidateSource
    }

    private struct NormalizedUnit {
        let character: Character
        let sourceRange: Range<String.Index>
    }

    private struct FlexibleMatch {
        let sourceRange: Range<String.Index>
        let normalizedLength: Int
    }

    private struct CandidateMatch {
        let match: FlexibleMatch
        let candidate: Candidate
    }

    private struct SurfaceRange {
        let text: String
        let range: Range<String.Index>
    }

    private struct RankedCandidate {
        let candidate: Candidate
        let score: Double
    }

    private struct PreparedCandidate {
        let candidate: Candidate
        let englishPhoneticKey: String?
        let chinesePinyinSyllables: [String]?
    }

    private struct ReplacementOperation {
        let range: Range<String.Index>
        let canonical: String
        let sourcePriority: Int
        let confidence: Double
    }

    static func resolve(
        segments: [RecognitionSegment],
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [ResolvedEntity] {
        let candidates = candidateList(
            lexicon: lexicon,
            snippets: snippets,
            hotwords: hotwords,
            context: context
        )
        let preparedCandidates = candidates.map { candidate in
            PreparedCandidate(
                candidate: candidate,
                englishPhoneticKey: candidate.source == .personalLexicon
                    ? englishPhoneticKey(candidate.alias)
                    : nil,
                chinesePinyinSyllables: candidate.source == .personalLexicon
                    ? pinyinSyllablesIfChinese(candidate.alias)
                    : nil
            )
        }
        var resolutions: [ResolvedEntity] = []
        var keys = Set<String>()

        for segment in segments {
            let exactMatches = candidates.flatMap { candidate in
                flexibleMatches(of: candidate.alias, in: segment.text).map {
                    CandidateMatch(match: $0, candidate: candidate)
                }
            }
            for match in selectedExactMatches(exactMatches, in: segment.text) {
                let surface = String(segment.text[match.match.sourceRange])
                let key = "\(segment.id)|\(presentationKey(surface))|\(presentationKey(match.candidate.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: surface,
                    canonical: match.candidate.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: match.candidate.source,
                    confidence: 1
                ))
            }

            let fuzzySurfaces = fuzzySurfaceRanges(
                in: segment.text,
                terminologyCandidates: candidates.filter { $0.source == .personalLexicon }
            )
            for surface in fuzzySurfaces {
                guard let resolved = resolveSurface(
                    surface.text,
                    candidates: preparedCandidates
                ) else { continue }
                let key = "\(segment.id)|\(presentationKey(surface.text))|\(presentationKey(resolved.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: surface.text,
                    canonical: resolved.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: resolved.source,
                    confidence: resolved.score
                ))
            }
        }
        return resolutions
    }

    /// 只替换已经由 resolve 命中的实体范围。替换操作先在原文上统一定位，
    /// 再从后向前落盘，避免 sequential global replace 产生级联或误伤单词子串。
    static func applying(_ resolutions: [ResolvedEntity], to text: String) -> String {
        let operations = resolutions.flatMap { resolution -> [ReplacementOperation] in
            guard resolution.confidence >= similarityThreshold,
                  !resolution.surfaceText.isEmpty,
                  !resolution.canonical.isEmpty,
                  resolution.surfaceText != resolution.canonical else { return [] }
            return flexibleMatches(of: resolution.surfaceText, in: text).map {
                ReplacementOperation(
                    range: $0.sourceRange,
                    canonical: resolution.canonical,
                    sourcePriority: resolution.candidateSource.priority,
                    confidence: resolution.confidence
                )
            }
        }
        let selected = selectedReplacementOperations(operations, in: text)
        var output = text
        for operation in selected.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(operation.range, with: operation.canonical)
        }
        return output
    }

    /// 将统一术语仓库已确认、无冲突的 alias 规则应用到 canonical 文本。
    /// 这里只做灵活精确匹配，不启用 fuzzy 推断，保证确定性纠错不会猜词。
    static func applyingKnownCorrections(
        _ corrections: [String: String],
        to text: String
    ) -> String {
        let candidates = corrections.map {
            Candidate(alias: $0.key, canonical: $0.value, source: .personalLexicon)
        }
        let matches = candidates.flatMap { candidate in
            flexibleMatches(of: candidate.alias, in: text).map {
                CandidateMatch(match: $0, candidate: candidate)
            }
        }
        let resolutions = selectedExactMatches(matches, in: text).map { match in
            ResolvedEntity(
                surfaceText: String(text[match.match.sourceRange]),
                canonical: match.candidate.canonical,
                sourceSegmentIDs: ["s1"],
                candidateSource: match.candidate.source,
                confidence: 1
            )
        }
        return applying(resolutions, to: text)
    }

    static func editSimilarity(_ left: String, _ right: String) -> Double {
        let a = Array(normalized(left))
        let b = Array(normalized(right))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...b.count)
        for (i, leftCharacter) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, rightCharacter) in b.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }

    private static func resolveSurface(
        _ surface: String,
        candidates: [PreparedCandidate]
    ) -> (canonical: String, source: EntityCandidateSource, score: Double)? {
        // 每个 surface 的转写只做一次；候选侧的发音键在本次 resolve 开始时预计算，
        // 避免中文滑窗 × 术语数量重复调用 Foundation transliteration 拉长本地延迟。
        let surfaceEnglishKey = englishPhoneticKey(surface)
        let surfacePinyinSyllables = pinyinSyllablesIfChinese(surface)
        let ranked = candidates.compactMap { prepared -> RankedCandidate? in
            let candidate = prepared.candidate
            let editScore = editSimilarity(surface, candidate.alias)
            var qualifiedScores = editScore >= similarityThreshold ? [editScore] : []

            // 发音通道只在统一术语白名单（运行时映射为 personalLexicon）中开启。
            // 固定整句替换和临时上下文不能靠近音猜测，避免把普通正文误当成术语。
            if candidate.source == .personalLexicon {
                if let leftKey = surfaceEnglishKey,
                   let rightKey = prepared.englishPhoneticKey {
                    let score = editSimilarity(leftKey, rightKey)
                    if score >= englishPhoneticThreshold {
                        qualifiedScores.append(score)
                    }
                }
                if let leftSyllables = surfacePinyinSyllables,
                   let rightSyllables = prepared.chinesePinyinSyllables,
                   let score = chinesePinyinSimilarity(leftSyllables, rightSyllables),
                   score >= chinesePinyinThreshold {
                    qualifiedScores.append(score)
                }
            }
            guard let score = qualifiedScores.max() else { return nil }
            return RankedCandidate(candidate: candidate, score: score)
        }.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.candidate.source.priority > right.candidate.source.priority
        }
        guard let best = ranked.first else { return nil }
        let competitor = ranked.first {
            normalized($0.candidate.canonical) != normalized(best.candidate.canonical)
        }
        guard competitor == nil || best.score - competitor!.score >= confidenceMargin else { return nil }
        return (best.candidate.canonical, best.candidate.source, best.score)
    }

    private static func candidateList(
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [Candidate] {
        var result: [Candidate] = []
        for entry in lexicon.entries where entry.isEnabled {
            result.append(Candidate(alias: entry.canonical, canonical: entry.canonical, source: .personalLexicon))
            result.append(contentsOf: entry.aliases.map {
                Candidate(alias: $0, canonical: entry.canonical, source: .personalLexicon)
            })
        }
        for snippet in snippets where !SnippetStorage.isDraftTrigger(snippet.trigger) {
            result.append(Candidate(
                alias: snippet.trigger,
                canonical: snippet.value,
                source: .snippet
            ))
            // 确定性纠错后 envelope 已经是 canonical；把标准写法也加入候选，
            // 让后续 LLM/Validator 继续把它当成受保护实体。
            result.append(Candidate(
                alias: snippet.value,
                canonical: snippet.value,
                source: .snippet
            ))
        }
        result.append(contentsOf: hotwords.map {
            Candidate(alias: $0, canonical: $0, source: .hotword)
        })
        if context.safety == .safe, context.level != .metadataOnly {
            let body = [context.selectedText, context.textBeforeCursor, context.textAfterCursor]
                .compactMap { $0 }
                .joined(separator: " ")
            result.append(contentsOf: tokens(in: body).map {
                Candidate(alias: $0, canonical: $0, source: .authorizedContext)
            })
        }
        return deduplicated(result)
    }

    private static func tokens(in text: String) -> [String] {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.map(String.init).filter { (2...64).contains($0.count) }
    }

    /// 为编辑距离与两个发音通道提供有界候选窗口。英文最多四个 token；中文只在
    /// 连续汉字 run 内、按白名单术语长度 ±1 滑窗，因此不会枚举整段正文的任意子串。
    private static func fuzzySurfaceRanges(
        in text: String,
        terminologyCandidates: [Candidate]
    ) -> [SurfaceRange] {
        var surfaces: [SurfaceRange] = tokenRanges(in: text)
        let wordRanges = surfaces.filter { isASCIIWordLike($0.text) }
        if wordRanges.count >= 2 {
            for start in wordRanges.indices {
                let maximumCount = min(4, wordRanges.count - start)
                guard maximumCount >= 2 else { continue }
                for count in 2...maximumCount {
                    let group = wordRanges[start..<(start + count)]
                    guard adjacentWordRanges(Array(group), in: text),
                          let first = group.first,
                          let last = group.last else { continue }
                    let range = first.range.lowerBound..<last.range.upperBound
                    surfaces.append(SurfaceRange(text: String(text[range]), range: range))
                }
            }
        }

        let chineseLengths = Set(terminologyCandidates.compactMap { candidate -> Int? in
            guard isAllHan(candidate.alias) else { return nil }
            let count = candidate.alias.count
            return count >= 2 ? count : nil
        })
        if !chineseLengths.isEmpty {
            for run in hanCharacterRuns(in: text) {
                for targetLength in chineseLengths {
                    let minimumLength = max(2, targetLength - 1)
                    let maximumLength = min(run.count, targetLength + 1)
                    guard minimumLength <= maximumLength else { continue }
                    for length in minimumLength...maximumLength {
                        for start in 0...(run.count - length) {
                            let range = run[start].lowerBound..<run[start + length - 1].upperBound
                            surfaces.append(SurfaceRange(text: String(text[range]), range: range))
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        return surfaces.filter { surface in
            guard (2...64).contains(surface.text.count) else { return false }
            let nsRange = NSRange(surface.range, in: text)
            return seen.insert("\(nsRange.location):\(nsRange.length)").inserted
        }
    }

    private static func tokenRanges(in text: String) -> [SurfaceRange] {
        var result: [SurfaceRange] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let separator = character.isWhitespace || character.isPunctuation
            if separator, let tokenStart = start {
                let range = tokenStart..<index
                result.append(SurfaceRange(text: String(text[range]), range: range))
                start = nil
            } else if !separator, start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let tokenStart = start {
            let range = tokenStart..<text.endIndex
            result.append(SurfaceRange(text: String(text[range]), range: range))
        }
        return result
    }

    private static func adjacentWordRanges(_ ranges: [SurfaceRange], in text: String) -> Bool {
        guard ranges.count >= 2 else { return true }
        for index in 1..<ranges.count {
            let gap = text[ranges[index - 1].range.upperBound..<ranges[index].range.lowerBound]
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "-" }) else { return false }
        }
        return true
    }

    private static func hanCharacterRuns(in text: String) -> [[Range<String.Index>]] {
        var runs: [[Range<String.Index>]] = []
        var current: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if isHan(text[index]) {
                current.append(index..<next)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
            index = next
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// 无外部依赖的保守英文发音键。它只折叠高确定性的拼写差异，并保留词边界；
    /// 最终是否替换仍需经过绝对阈值和候选领先幅度两道门槛。
    private static func englishPhoneticKey(_ value: String) -> String? {
        guard isASCIIWordLike(value) else { return nil }
        let words = value.lowercased().split {
            !$0.unicodeScalars.allSatisfy(\.isASCII) || !$0.isLetter
        }
        guard !words.isEmpty else { return nil }
        let keys = words.compactMap { rawWord -> String? in
            var word = String(rawWord)
            guard word.count >= 2 else { return nil }
            if word.hasPrefix("kn") { word.removeFirst() }
            if word.hasPrefix("wr") { word.removeFirst() }
            let replacements = [
                ("tion", "shun"), ("sion", "shun"), ("tch", "ch"),
                ("dge", "j"), ("igh", "i"), ("ght", "t"),
                ("ph", "f"), ("ck", "k"), ("qu", "k")
            ]
            for (source, target) in replacements {
                word = word.replacingOccurrences(of: source, with: target)
            }
            if word.count > 2, word.hasSuffix("e") { word.removeLast() }
            word = word.replacingOccurrences(of: "c", with: "k")
                .replacingOccurrences(of: "q", with: "k")
                .replacingOccurrences(of: "x", with: "ks")

            var result = ""
            var previous: Character?
            for character in word {
                let normalizedCharacter: Character = "aeiouy".contains(character) ? "a" : character
                guard normalizedCharacter != previous else { continue }
                result.append(normalizedCharacter)
                previous = normalizedCharacter
            }
            return result.count >= 2 ? result : nil
        }
        guard keys.count == words.count else { return nil }
        return keys.joined(separator: "|")
    }

    private static func chinesePinyinSimilarity(
        _ leftSyllables: [String],
        _ rightSyllables: [String]
    ) -> Double? {
        guard abs(leftSyllables.count - rightSyllables.count) <= 1 else { return nil }
        let joinedScore = editSimilarity(
            leftSyllables.joined(separator: "|"),
            rightSyllables.joined(separator: "|")
        )
        guard leftSyllables.count == rightSyllables.count else {
            return joinedScore * 0.9
        }
        let syllableScore = zip(leftSyllables, rightSyllables)
            .map { editSimilarity($0, $1) }
            .reduce(0, +) / Double(leftSyllables.count)
        return max(joinedScore, syllableScore)
    }

    private static func pinyinSyllablesIfChinese(_ value: String) -> [String]? {
        guard isAllHan(value) else { return nil }
        return pinyinSyllables(value)
    }

    private static func pinyinSyllables(_ value: String) -> [String]? {
        guard let latin = value.applyingTransform(.mandarinToLatin, reverse: false) else {
            return nil
        }
        // 保留声调符号。去掉声调会把“飞书 / 非数”都折叠成 `fei shu`，
        // 在只有一个白名单候选时造成高置信误替换。
        let normalizedLatin = latin.precomposedStringWithCanonicalMapping.lowercased()
        let syllables = normalizedLatin.split { !$0.isLetter }.map(String.init)
        return syllables.isEmpty ? nil : syllables
    }

    private static func isASCIIWordLike(_ value: String) -> Bool {
        var letterCount = 0
        for scalar in value.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.isASCII else { return false }
                letterCount += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar),
                      !"-_‐‑‒–—﹘﹣－".unicodeScalars.contains(scalar) {
                return false
            }
        }
        return letterCount >= 4
    }

    private static func isAllHan(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(isHan)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var bestByPair: [String: Candidate] = [:]
        for candidate in candidates {
            let aliasKey = normalized(candidate.alias)
            let canonicalKey = normalized(candidate.canonical)
            guard !aliasKey.isEmpty, !canonicalKey.isEmpty else { continue }
            let key = "\(aliasKey)→\(canonicalKey)"
            if let existing = bestByPair[key], existing.source.priority >= candidate.source.priority {
                continue
            }
            bestByPair[key] = candidate
        }
        return Array(bestByPair.values)
    }

    private static func selectedExactMatches(
        _ matches: [CandidateMatch],
        in text: String
    ) -> [CandidateMatch] {
        let byRange = Dictionary(grouping: matches) {
            let range = NSRange($0.match.sourceRange, in: text)
            return "\(range.location):\(range.length)"
        }
        let unambiguous = byRange.values.compactMap { group -> CandidateMatch? in
            let ranked = group.sorted { left, right in
                if left.candidate.source.priority != right.candidate.source.priority {
                    return left.candidate.source.priority > right.candidate.source.priority
                }
                return left.match.normalizedLength > right.match.normalizedLength
            }
            guard let best = ranked.first else { return nil }
            let competitor = ranked.first {
                $0.candidate.source.priority == best.candidate.source.priority
                    && $0.match.normalizedLength == best.match.normalizedLength
                    && normalized($0.candidate.canonical) != normalized(best.candidate.canonical)
            }
            return competitor == nil ? best : nil
        }
        let ranked = unambiguous.sorted { left, right in
            let leftRange = NSRange(left.match.sourceRange, in: text)
            let rightRange = NSRange(right.match.sourceRange, in: text)
            if leftRange.length != rightRange.length { return leftRange.length > rightRange.length }
            if left.candidate.source.priority != right.candidate.source.priority {
                return left.candidate.source.priority > right.candidate.source.priority
            }
            return leftRange.location < rightRange.location
        }
        var selected: [CandidateMatch] = []
        var occupied: [NSRange] = []
        for match in ranked {
            let range = NSRange(match.match.sourceRange, in: text)
            guard occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) else { continue }
            selected.append(match)
            occupied.append(range)
        }
        return selected.sorted {
            $0.match.sourceRange.lowerBound < $1.match.sourceRange.lowerBound
        }
    }

    private static func selectedReplacementOperations(
        _ operations: [ReplacementOperation],
        in text: String
    ) -> [ReplacementOperation] {
        let byRange = Dictionary(grouping: operations) {
            let range = NSRange($0.range, in: text)
            return "\(range.location):\(range.length)"
        }
        let unambiguous = byRange.values.compactMap { group -> ReplacementOperation? in
            let ranked = group.sorted { left, right in
                if left.sourcePriority != right.sourcePriority {
                    return left.sourcePriority > right.sourcePriority
                }
                return left.confidence > right.confidence
            }
            guard let best = ranked.first else { return nil }
            let competitor = ranked.first {
                $0.sourcePriority == best.sourcePriority
                    && $0.confidence == best.confidence
                    && normalized($0.canonical) != normalized(best.canonical)
            }
            return competitor == nil ? best : nil
        }
        let ranked = unambiguous.sorted { left, right in
            let leftRange = NSRange(left.range, in: text)
            let rightRange = NSRange(right.range, in: text)
            if leftRange.length != rightRange.length { return leftRange.length > rightRange.length }
            if left.sourcePriority != right.sourcePriority {
                return left.sourcePriority > right.sourcePriority
            }
            return leftRange.location < rightRange.location
        }
        var selected: [ReplacementOperation] = []
        var occupied: [NSRange] = []
        for operation in ranked {
            let range = NSRange(operation.range, in: text)
            guard occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) else { continue }
            selected.append(operation)
            occupied.append(range)
        }
        return selected
    }

    /// 在忽略大小写、内部空白和连字符的视图上匹配，同时保留到原始 String.Range
    /// 的映射。边界只约束 ASCII 单词，英文术语可以自然嵌在中文句子中。
    private static func flexibleMatches(of alias: String, in text: String) -> [FlexibleMatch] {
        let needle = Array(normalized(alias))
        guard needle.count >= 2 else { return [] }
        let haystack = normalizedUnits(in: text)
        guard haystack.count >= needle.count else { return [] }

        var result: [FlexibleMatch] = []
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            guard zip(haystack[start..<end], needle).allSatisfy({ $0.character == $1 }) else {
                continue
            }
            let range = haystack[start].sourceRange.lowerBound..<haystack[end - 1].sourceRange.upperBound
            guard hasValidBoundaries(
                range: range,
                first: needle[0],
                last: needle[needle.count - 1],
                in: text
            ) else { continue }
            result.append(FlexibleMatch(
                sourceRange: range,
                normalizedLength: needle.count
            ))
        }
        return result
    }

    private static func normalizedUnits(in value: String) -> [NormalizedUnit] {
        var units: [NormalizedUnit] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            let sourceRange = index..<next
            let folded = String(value[sourceRange])
                .precomposedStringWithCompatibilityMapping
                .lowercased()
            for character in folded where !isIgnoredSeparator(character) {
                units.append(NormalizedUnit(
                    character: character,
                    sourceRange: sourceRange
                ))
            }
            index = next
        }
        return units
    }

    private static func hasValidBoundaries(
        range: Range<String.Index>,
        first: Character,
        last: Character,
        in text: String
    ) -> Bool {
        if isASCIIAlphaNumeric(first), range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if isASCIIAlphaNumeric(previous) { return false }
        }
        if isASCIIAlphaNumeric(last), range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if isASCIIAlphaNumeric(next) { return false }
        }
        return true
    }

    private static func isIgnoredSeparator(_ character: Character) -> Bool {
        if character.isWhitespace {
            let value = String(character)
            return !value.contains("\n") && !value.contains("\r")
        }
        return "-‐‑‒–—﹘﹣－".contains(character)
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private static func presentationKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
    }

    private static func normalized(_ value: String) -> String {
        String(normalizedUnits(in: value).map(\.character))
    }
}
