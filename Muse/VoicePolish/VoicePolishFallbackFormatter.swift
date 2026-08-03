import Foundation

/// LLM 失败或版式校验失败时，对 canonical 正文执行的纯版式回退。
///
/// 允许的变化只有空白、换行和列表标记；任何无法由本地确定性规则证明安全的
/// 拆分都会放弃，直接返回 `request.fallbackText`。
enum VoicePolishFallbackFormatter {
    static func format(
        request: VoicePolishRequest,
        expectation: VoicePolishLayoutExpectation
    ) -> String {
        let rawSource = request.fallbackText
        if request.context.scene == .code {
            return rawSource
        }
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return source }
        if expectation.forbidsLineBreaks {
            return singleLineCandidate(source, expectation: expectation) ?? source
        }
        if listKindIsForbidden(expectation) {
            return source
        }

        let candidate: String?
        switch expectation.kind {
        case .sentence:
            candidate = nil
        case .paragraphs:
            candidate = paragraphCandidate(
                source: source,
                request: request,
                minimumCount: expectation.minimumParagraphCount
            )
        case .numberedList, .bulletList:
            candidate = listCandidate(
                source: source,
                expectation: expectation,
                allowsSemicolonSplitting: request.context.scene != .code
            )
        }

        guard let candidate,
              isStrictlySafeTransformation(
                source: source,
                candidate: candidate,
                expectation: expectation
              ) else {
            return source
        }
        return candidate
    }

    /// 对 LLM 成稿做纯版式本地修正。与 canonical 回退不同，这里不借用原始
    /// segments，只在成稿本身存在可证明的句界或列表边界时调整排版。
    static func formatCandidate(
        _ text: String,
        expectation: VoicePolishLayoutExpectation
    ) -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return source }
        if expectation.forbidsLineBreaks {
            return singleLineCandidate(source, expectation: expectation) ?? source
        }
        if listKindIsForbidden(expectation) {
            return source
        }

        let candidate: String?
        switch expectation.kind {
        case .sentence:
            candidate = nil
        case .paragraphs:
            candidate = paragraphCandidate(
                source: source,
                minimumCount: expectation.minimumParagraphCount
            )
        case .numberedList, .bulletList:
            candidate = listCandidate(
                source: source,
                expectation: expectation,
                allowsSemicolonSplitting: true
            )
        }

        guard let candidate,
              isStrictlySafeTransformation(
                source: source,
                candidate: candidate,
                expectation: expectation
              ) else {
            return source
        }
        return candidate
    }

    /// 严格、方向性的本地排版安全门。
    ///
    /// `source` 只允许剥离经保守解析证明为原有列表结构的标记；`candidate`
    /// 只允许剥离当前契约生成且序列完整的列表标记。除此之外仅忽略空白，分号、
    /// 顿号、URL、路径、负号及代码字符都必须逐字符、按原顺序保留。
    static func isStrictlySafeTransformation(
        source: String,
        candidate: String,
        expectation: VoicePolishLayoutExpectation
    ) -> Bool {
        let sourceNeutral = removingContinuousInlineOrdinalMarkers(
            in: VoicePolishNumbering.removingProvenListLineMarkers(in: source)
        )
        var candidateNeutral: String
        switch expectation.kind {
        case .numberedList:
            candidateNeutral = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                in: candidate
            )
        case .bulletList:
            candidateNeutral = removingGeneratedBulletLineMarkers(
                in: candidate,
                expectation: expectation
            )
        case .sentence, .paragraphs:
            candidateNeutral = VoicePolishNumbering.removingProvenListLineMarkers(
                in: candidate
            )
        }
        candidateNeutral = removingContinuousInlineOrdinalMarkers(in: candidateNeutral)
        return compactText(sourceNeutral) == compactText(candidateNeutral)
    }
}

private extension VoicePolishFallbackFormatter {
    struct ListParts: Sendable, Equatable {
        let prefix: String?
        let items: [String]
    }

    struct InlineMarker: Sendable, Equatable {
        let range: Range<String.Index>
        let ordinal: Int
    }

    struct ProvenSegmentParts: Sendable, Equatable {
        let units: [String]
        let separators: [String]
    }

    static func listKindIsForbidden(_ expectation: VoicePolishLayoutExpectation) -> Bool {
        switch expectation.kind {
        case .numberedList:
            return expectation.forbidsNumberedList
        case .bulletList:
            return expectation.forbidsBulletList
        case .sentence, .paragraphs:
            return false
        }
    }

    static func singleLineCandidate(
        _ source: String,
        expectation: VoicePolishLayoutExpectation
    ) -> String? {
        var candidate = VoicePolishCharacterSafety.normalizedLineEndings(source)

        if expectation.forbidsNumberedList,
           VoicePolishNumbering.listItemCount(in: candidate, kind: .numberedList) > 0 {
            let stripped = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                in: candidate
            )
            guard stripped != candidate else { return nil }
            candidate = stripped
        }

        if expectation.forbidsBulletList,
           VoicePolishNumbering.listItemCount(in: candidate, kind: .bulletList) > 0 {
            let stripped = VoicePolishNumbering.removingProvenBulletLineMarkers(in: candidate)
            guard stripped != candidate else { return nil }
            candidate = stripped
        }

        return candidate
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Paragraphs

    static func paragraphCandidate(
        source: String,
        request: VoicePolishRequest,
        minimumCount: Int
    ) -> String? {
        let requiredCount = max(2, minimumCount)
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(source)
        if paragraphCount(in: normalized) >= requiredCount {
            return normalized
        }

        let segmentTexts = request.input.segments.compactMap { segment -> String? in
            let resolved = EntityResolver.applying(request.resolvedEntities, to: segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return resolved.isEmpty ? nil : resolved
        }
        if segmentTexts.count >= requiredCount,
           let parts = provenSegmentParts(source: normalized, units: segmentTexts) {
            return groupedParagraphsPreservingSeparators(
                parts,
                paragraphCount: requiredCount
            )
        }

        let sentences = sentenceUnits(in: normalized)
        guard sentences.count >= requiredCount else { return nil }
        return groupedParagraphs(
            sentences,
            paragraphCount: requiredCount,
            withinGroupSeparator: containsCJK(source) ? "" : " "
        )
    }

    static func paragraphCandidate(
        source: String,
        minimumCount: Int
    ) -> String? {
        let requiredCount = max(2, minimumCount)
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(source)
        if paragraphCount(in: normalized) >= requiredCount {
            return normalized
        }
        let sentences = sentenceUnits(in: normalized)
        guard sentences.count >= requiredCount else { return nil }
        return groupedParagraphs(
            sentences,
            paragraphCount: requiredCount,
            withinGroupSeparator: containsCJK(source) ? "" : " "
        )
    }

    static func groupedParagraphs(
        _ units: [String],
        paragraphCount: Int,
        withinGroupSeparator: String
    ) -> String {
        let groupCount = min(max(1, paragraphCount), units.count)
        let baseSize = units.count / groupCount
        let remainder = units.count % groupCount
        var cursor = 0
        var paragraphs: [String] = []

        for groupIndex in 0..<groupCount {
            let size = baseSize + (groupIndex < remainder ? 1 : 0)
            let end = cursor + size
            paragraphs.append(
                units[cursor..<end].joined(separator: withinGroupSeparator)
            )
            cursor = end
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func provenSegmentParts(
        source: String,
        units: [String]
    ) -> ProvenSegmentParts? {
        let normalizedSource = VoicePolishCharacterSafety.normalizedLineEndings(source)
        let normalizedUnits = units.map {
            VoicePolishCharacterSafety.normalizedLineEndings($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalizedUnits.isEmpty,
              normalizedUnits.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var cursor = normalizedSource.startIndex
        var separators: [String] = []
        for (offset, unit) in normalizedUnits.enumerated() {
            if offset > 0 {
                let separatorStart = cursor
                while cursor < normalizedSource.endIndex,
                      normalizedSource[cursor].isWhitespace {
                    cursor = normalizedSource.index(after: cursor)
                }
                separators.append(String(normalizedSource[separatorStart..<cursor]))
            }
            guard normalizedSource[cursor...].hasPrefix(unit) else { return nil }
            cursor = normalizedSource.index(cursor, offsetBy: unit.count)
        }
        guard normalizedSource[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        return ProvenSegmentParts(units: normalizedUnits, separators: separators)
    }

    static func groupedParagraphsPreservingSeparators(
        _ parts: ProvenSegmentParts,
        paragraphCount: Int
    ) -> String {
        let groupCount = min(max(1, paragraphCount), parts.units.count)
        let baseSize = parts.units.count / groupCount
        let remainder = parts.units.count % groupCount
        var cursor = 0
        var paragraphs: [String] = []

        for groupIndex in 0..<groupCount {
            let size = baseSize + (groupIndex < remainder ? 1 : 0)
            let end = cursor + size
            var paragraph = parts.units[cursor]
            if size > 1 {
                for unitIndex in (cursor + 1)..<end {
                    paragraph += parts.separators[unitIndex - 1]
                    paragraph += parts.units[unitIndex]
                }
            }
            paragraphs.append(paragraph)
            cursor = end
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func sentenceUnits(in text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = text.startIndex
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let character = text[cursor]
            let next = text.index(after: cursor)
            if isSentenceBoundary(character, at: cursor, in: text) {
                var sentenceEnd = next
                while sentenceEnd < text.endIndex,
                      closingCharacters.contains(text[sentenceEnd]) {
                    sentenceEnd = text.index(after: sentenceEnd)
                }
                let sentence = text[sentenceStart..<sentenceEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    result.append(sentence)
                }
                sentenceStart = sentenceEnd
                cursor = sentenceEnd
            } else {
                cursor = next
            }
        }

        let tail = text[sentenceStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    static func isSentenceBoundary(
        _ character: Character,
        at index: String.Index,
        in text: String
    ) -> Bool {
        if "。！？!?".contains(character) { return true }
        guard character == "." else { return false }

        let previous = index > text.startIndex ? text[text.index(before: index)] : nil
        let nextIndex = text.index(after: index)
        let next = nextIndex < text.endIndex ? text[nextIndex] : nil
        if let previous, let next, isArabicDigit(previous), isArabicDigit(next) {
            return false
        }
        if isCommonAbbreviationPeriod(at: index, in: text) {
            return false
        }
        return next == nil || next?.isWhitespace == true || closingCharacters.contains(next!)
    }

    static func isCommonAbbreviationPeriod(
        at index: String.Index,
        in text: String
    ) -> Bool {
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard character.isLetter || character == "." else { break }
            start = previous
        }
        let token = text[start..<index].lowercased()
        let common = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
            "e.g", "i.e", "u.s", "u.k",
        ]
        if common.contains(token) { return true }
        return token.range(
            of: #"^(?:[a-z]\.)+[a-z]$"#,
            options: .regularExpression
        ) != nil
    }

    static let closingCharacters: Set<Character> = [
        "”", "’", "\"", "'", "」", "』", "》", "）", ")", "】", "]",
    ]

    static func paragraphCount(in text: String) -> Int {
        let blankLineBlocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if blankLineBlocks.count > 1 { return blankLineBlocks.count }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    // MARK: - Lists

    static func listCandidate(
        source: String,
        expectation: VoicePolishLayoutExpectation,
        allowsSemicolonSplitting: Bool
    ) -> String? {
        let recognizedLineCount = VoicePolishNumbering.recognizedListItemCount(in: source)
        if recognizedLineCount >= 2 {
            guard countSatisfiesContract(recognizedLineCount, expectation: expectation) else {
                return nil
            }
            let normalized = VoicePolishNumbering.normalizeExistingList(
                in: source,
                as: expectation.kind
            )
            let styled = applyRequestedNumberingStyle(
                to: normalized,
                expectation: expectation
            )
            let formattedCount = VoicePolishNumbering.listItemCount(
                in: styled,
                kind: expectation.kind
            )
            guard countSatisfiesContract(formattedCount, expectation: expectation) else {
                return nil
            }
            if expectation.kind == .numberedList,
               !VoicePolishNumbering.matchesNumberingPreference(
                   in: styled,
                   preference: expectation.numberingPreference
               ) {
                return nil
            }
            return styled
        }

        for markers in inlineMarkerCandidates(in: source) {
            guard markerSequenceIsValid(markers),
                  countSatisfiesContract(markers.count, expectation: expectation),
                  let parts = inlineListParts(source: source, markers: markers) else {
                continue
            }
            return render(parts, expectation: expectation)
        }

        // 单个行首疑似编号既不能证明为完整列表，也不能当作普通无标记行重排。
        guard recognizedLineCount == 0,
              !VoicePolishNumbering.containsPotentialListMarker(in: source) else {
            return nil
        }

        if let parts = unmarkedLineParts(in: source, expectation: expectation) {
            return render(parts, expectation: expectation)
        }

        if allowsSemicolonSplitting,
           let parts = semicolonSeparatedParts(in: source),
           countSatisfiesContract(parts.items.count, expectation: expectation) {
            return render(parts, expectation: expectation)
        }
        if let parts = ideographicSeparatedParts(
            in: source,
            expectation: expectation
        ) {
            return render(parts, expectation: expectation)
        }
        return nil
    }

    static func unmarkedLineParts(
        in source: String,
        expectation: VoicePolishLayoutExpectation
    ) -> ListParts? {
        let lines = VoicePolishCharacterSafety.normalizedLineEndings(source)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        if lines.count >= 3,
           lines[0].last.map({ $0 == "：" || $0 == ":" }) == true,
           countSatisfiesContract(lines.count - 1, expectation: expectation) {
            return ListParts(prefix: lines[0], items: Array(lines.dropFirst()))
        }
        guard countSatisfiesContract(lines.count, expectation: expectation) else { return nil }
        return ListParts(prefix: nil, items: lines)
    }

    static func inlineMarkerCandidates(in source: String) -> [[InlineMarker]] {
        [
            chineseOrdinalMarkers(in: source),
            chineseNumeralMarkers(in: source),
            englishOrdinalMarkers(in: source),
        ]
    }

    static func chineseOrdinalMarkers(in source: String) -> [InlineMarker] {
        regexMarkers(
            pattern: #"第([一二三四五六七八九十]{1,3}|\d+)(?:个|点|条|项|步|部分|方面)?(?:是|[，、,:：.）)]|[ \t]+)"#,
            source: source
        ) { captured in
            integer(fromChineseOrArabic: captured)
        }
    }

    static func chineseNumeralMarkers(in source: String) -> [InlineMarker] {
        regexMarkers(
            pattern: #"(?<![零〇一二两三四五六七八九十百千万亿])([一二三四五六七八九十]{1,3})(?:是|[、.)）])"#,
            source: source
        ) { captured in
            integer(fromChineseOrArabic: captured)
        }
    }

    static func englishOrdinalMarkers(in source: String) -> [InlineMarker] {
        let words = "first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?|sixth(?:ly)?|seventh(?:ly)?|eighth(?:ly)?|ninth(?:ly)?|tenth(?:ly)?"
        return regexMarkers(
            pattern: #"\b("# + words + #")\b(?:[ \t]*[,.:)]|[ \t]+)"#,
            source: source,
            options: [.caseInsensitive]
        ) { captured in
            englishOrdinal(captured)
        }
    }

    static func regexMarkers(
        pattern: String,
        source: String,
        options: NSRegularExpression.Options = [],
        ordinal: (String) -> Int?
    ) -> [InlineMarker] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let markerRange = Range(match.range(at: 0), in: source),
                  let captureRange = Range(match.range(at: 1), in: source),
                  let value = ordinal(String(source[captureRange])) else {
                return nil
            }
            return InlineMarker(range: markerRange, ordinal: value)
        }
    }

    static func markerSequenceIsValid(_ markers: [InlineMarker]) -> Bool {
        guard markers.count >= 2 else { return false }
        return markers.enumerated().allSatisfy { offset, marker in
            marker.ordinal == offset + 1
        }
    }

    static func inlineListParts(
        source: String,
        markers: [InlineMarker]
    ) -> ListParts? {
        guard let first = markers.first else { return nil }
        let prefix = source[..<first.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [String] = []

        for index in markers.indices {
            let start = markers[index].range.upperBound
            let end = index + 1 < markers.count
                ? markers[index + 1].range.lowerBound
                : source.endIndex
            let item = source[start..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return nil }
            items.append(item)
        }
        return ListParts(prefix: prefix.isEmpty ? nil : prefix, items: items)
    }

    static func semicolonSeparatedParts(in source: String) -> ListParts? {
        guard let colon = safeIntroductoryColon(in: source) else { return nil }
        let afterColon = source.index(after: colon)
        let heading = source[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = source[...colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(source[afterColon...])
        guard !prefix.isEmpty,
              !isCodeOrCommandHeading(heading),
              !containsCodePathOrCommandRisk(body) else { return nil }

        let separators = CharacterSet(
            charactersIn: containsURLOrDataURI(body) ? "；" : ";；"
        )
        let items = splitRetainingDelimiters(in: body, separators: separators)
        guard items.count >= 2 else { return nil }
        return ListParts(prefix: prefix, items: items)
    }

    static func ideographicSeparatedParts(
        in source: String,
        expectation: VoicePolishLayoutExpectation
    ) -> ListParts? {
        guard expectation.kind == .numberedList || expectation.kind == .bulletList else {
            return nil
        }

        for delimiter in ["、", "，"] {
            if let colon = safeIntroductoryColon(in: source) {
                let afterColon = source.index(after: colon)
                let heading = source[..<colon]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(source[afterColon...])
                let prefix = source[...colon]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let items = splitRetainingDelimiters(
                    in: body,
                    separators: CharacterSet(charactersIn: delimiter)
                )
                if !prefix.isEmpty,
                   !isCodeOrCommandHeading(heading),
                   !containsCodePathOrCommandRisk(body),
                   countSatisfiesContract(items.count, expectation: expectation) {
                    return ListParts(prefix: prefix, items: items)
                }
            }

            let parts = splitRetainingDelimiters(
                in: source,
                separators: CharacterSet(charactersIn: delimiter)
            )
            guard parts.count >= 3,
                  let first = parts.first else { continue }
            let heading = String(first.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let items = Array(parts.dropFirst())
            guard !heading.isEmpty,
                  isSafeListHeading(heading),
                  !isCodeOrCommandHeading(heading),
                  !containsCodePathOrCommandRisk(items.joined()),
                  countSatisfiesContract(items.count, expectation: expectation) else {
                continue
            }
            return ListParts(prefix: first, items: items)
        }
        return nil
    }

    static func splitRetainingDelimiters(
        in source: String,
        separators: CharacterSet
    ) -> [String] {
        var parts: [String] = []
        var start = source.startIndex
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let next = source.index(after: cursor)
            if source[cursor].unicodeScalars.allSatisfy(separators.contains) {
                let part = source[start..<next]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { parts.append(part) }
                start = next
            }
            cursor = next
        }
        let tail = source[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    static func containsCodePathOrCommandRisk(_ source: String) -> Bool {
        let withoutURLs = source.replacingOccurrences(
            of: #"(?i)(?:https?|data):[^\s；]+"#,
            with: "",
            options: .regularExpression
        )
        let patterns = [
            #"(?:^|[\s：:])(?:~/|/)[^\s;；]+"#,
            #"[A-Za-z]:\\[^\s;；]+"#,
            #"\$[A-Za-z_{(]"#,
            #"&&|\|\||;;|=>|:=|[{}]"#,
            #"(?i)(?:^|[;；]\s*)(?:for|while|until|if|then|do|done|fi|case|esac|function|let|var|const|return)\b"#,
            #"\b[A-Za-z_][A-Za-z0-9_]*\s*="#,
            #"\b[A-Za-z_][A-Za-z0-9_.]*\("#,
            #"(?i)(?:^|[;；]\s*)(?:(?:sudo|env|command|builtin|time)\s+)*(?:bash|zsh|sh|fish|echo|printf|cd|pwd|ls|cat|head|tail|grep|rg|sed|awk|find|xargs|curl|wget|git|npm|pnpm|yarn|bun|node|python3?|ruby|swift|cargo|docker|kubectl|brew|chmod|chown|cp|mv|mkdir|touch|open|defaults|launchctl|killall?)\b"#,
            #"(?i)(?:^|[;；]\s*)(?:select|insert|update|delete|create|alter|drop)\b"#,
            #"(?:^|\s)\d*(?:>>?|<)\s*\S"#,
            #"`[^`]*`"#,
        ]
        return patterns.contains {
            withoutURLs.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func isCodeOrCommandHeading(_ heading: String) -> Bool {
        let compact = heading
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let patterns = [
            #"代码|命令|指令|脚本|终端|函数|调用|查询语句"#,
            #"\b(?:code|commands?|shell|scripts?|terminal|bash|zsh|functions?|calls?|sql|queries?)\b"#,
        ]
        return patterns.contains {
            compact.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func safeIntroductoryColon(in firstPart: String) -> String.Index? {
        for index in firstPart.indices {
            let character = firstPart[index]
            guard character == "：" || character == ":" else { continue }
            let heading = firstPart[..<index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty, heading.count <= 80 else { continue }

            let nextIndex = firstPart.index(after: index)
            if character == ":" {
                let previous = index > firstPart.startIndex
                    ? firstPart[firstPart.index(before: index)]
                    : nil
                let next = nextIndex < firstPart.endIndex ? firstPart[nextIndex] : nil
                if let previous, let next,
                   isArabicDigit(previous), isArabicDigit(next) {
                    continue
                }
                if nextIndex < firstPart.endIndex,
                   firstPart[nextIndex...].hasPrefix("//") {
                    continue
                }
            }
            guard isSafeListHeading(heading) else { continue }
            return index
        }
        return nil
    }

    static func isSafeListHeading(_ heading: String) -> Bool {
        let compact = heading
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let chineseSuffixes = [
            "包括", "如下", "分别为", "分别是", "有", "事项", "问题", "任务", "步骤",
            "要点", "点", "条", "项", "件事", "方面", "部分", "原因", "建议", "计划",
            "内容", "重点", "待办", "清单", "时间", "链接", "网址",
        ]
        if chineseSuffixes.contains(where: { compact.hasSuffix($0) }) {
            return true
        }
        return compact.range(
            of: #"(?:includes?|including|as follows|tasks?|items?|steps?|points?|reasons?|recommendations?|plans?|problems?|issues?|times?|links?|urls?)\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func render(
        _ parts: ListParts,
        expectation: VoicePolishLayoutExpectation
    ) -> String {
        let renderedItems = parts.items.enumerated().map { offset, item in
            switch expectation.kind {
            case .numberedList:
                if expectation.numberingPreference == .chinese,
                   let number = chineseNumber(offset + 1) {
                    return "\(number)、\(item)"
                }
                return "\(offset + 1). \(item)"
            case .bulletList:
                return "- \(item)"
            case .sentence, .paragraphs:
                return item
            }
        }
        if let prefix = parts.prefix {
            return prefix + "\n\n" + renderedItems.joined(separator: "\n")
        }
        return renderedItems.joined(separator: "\n")
    }

    static func applyRequestedNumberingStyle(
        to text: String,
        expectation: VoicePolishLayoutExpectation
    ) -> String {
        guard expectation.kind == .numberedList,
              expectation.numberingPreference == .chinese else {
            return text
        }

        guard VoicePolishNumbering.matchesNumberingPreference(
            in: text,
            preference: .arabic
        ) else {
            return text
        }

        var ordinal = 0
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*)\d+\.\s+"#) else {
            return text
        }
        return VoicePolishCharacterSafety.normalizedLineEndings(text)
            .components(separatedBy: "\n")
            .map { line in
                guard let match = regex.firstMatch(
                        in: line,
                        range: NSRange(line.startIndex..<line.endIndex, in: line)
                      ),
                      match.range.location == 0,
                      let fullRange = Range(match.range(at: 0), in: line),
                      let indentationRange = Range(match.range(at: 1), in: line),
                      let number = chineseNumber(ordinal + 1) else {
                    return line
                }
                ordinal += 1
                return String(line[indentationRange]) + number + "、" + line[fullRange.upperBound...]
            }
            .joined(separator: "\n")
    }

    static func countSatisfiesContract(
        _ count: Int,
        expectation: VoicePolishLayoutExpectation
    ) -> Bool {
        if let expected = expectation.expectedListItemCount {
            return count == expected
        }
        return count >= max(2, expectation.minimumListItemCount ?? 2)
    }

    // MARK: - Safety invariants

    static func removingGeneratedBulletLineMarkers(
        in text: String,
        expectation: VoicePolishLayoutExpectation
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[ \t]*(?:[-*–—][ \t]+|[•·▪◦‣][ \t]*)(.+)$"#
        ) else { return text }
        var lines = VoicePolishCharacterSafety.normalizedLineEndings(text)
            .components(separatedBy: "\n")
        var matched: [(index: Int, content: String)] = []
        for index in lines.indices {
            let line = lines[index]
            guard let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ), let contentRange = Range(match.range(at: 1), in: line) else { continue }
            let content = line[contentRange].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return text }
            matched.append((index, content))
        }
        guard countSatisfiesContract(matched.count, expectation: expectation) else {
            return text
        }
        for item in matched { lines[item.index] = item.content }
        return lines.joined(separator: "\n")
    }

    static func compactText(_ text: String) -> String {
        VoicePolishCharacterSafety.normalizedLineEndings(text)
            .filter { !$0.isWhitespace }
    }

    static func containsURLOrDataURI(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("http://")
            || normalized.contains("https://")
            || normalized.contains("data:")
    }

    static func removingContinuousInlineOrdinalMarkers(in text: String) -> String {
        for markers in inlineMarkerCandidates(in: text) where markerSequenceIsValid(markers) {
            var result = text
            for marker in markers.reversed() {
                result.removeSubrange(marker.range)
            }
            return result
        }
        return text
    }

    // MARK: - Ordinals

    static func integer(fromChineseOrArabic text: String) -> Int? {
        if let value = Int(text) { return value }
        guard let canonical = ProtectedFactExtractor.canonicalChineseNumber(text) else {
            return nil
        }
        return Int(canonical)
    }

    static func englishOrdinal(_ text: String) -> Int? {
        switch text.lowercased() {
        case "first", "firstly": return 1
        case "second", "secondly": return 2
        case "third", "thirdly": return 3
        case "fourth", "fourthly": return 4
        case "fifth", "fifthly": return 5
        case "sixth", "sixthly": return 6
        case "seventh", "seventhly": return 7
        case "eighth", "eighthly": return 8
        case "ninth", "ninthly": return 9
        case "tenth", "tenthly": return 10
        default: return nil
        }
    }

    static func chineseNumber(_ number: Int) -> String? {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard (1...99).contains(number) else { return nil }
        if number < 10 { return digits[number] }
        let tens = number / 10
        let ones = number % 10
        let prefix = tens == 1 ? "十" : digits[tens] + "十"
        return ones == 0 ? prefix : prefix + digits[ones]
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
        }
    }

    static func isArabicDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}
