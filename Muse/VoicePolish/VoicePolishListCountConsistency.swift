import Foundation

/// 对已经形成的列表校验总数，并在来源与成稿双重证据充分时同步声明。
///
/// 这里只允许改动唯一总数声明里的数字。列表正文、标点、空白及编号都不会变化；
/// 任何歧义、否定、引用、示例或代码风险都会让同步直接放弃。
enum VoicePolishListCountConsistency {
    /// 只有 canonical source 与候选成稿都能独立证明
    /// “原有 N 项 + 尾随明确新增 1 项 = 连续 N+1 项”时，才将候选成稿中的
    /// 唯一总数声明由 N 改为 N+1；证据不足时原样返回。
    static func synchronizeDeclaredCountForProvenTrailingAddition(
        in text: String,
        canonicalSource: String
    ) -> String {
        guard let evidence = synchronizationEvidence(in: text),
              evidence.normalizedText == text,
              evidence.listCount == evidence.declaration.count + 1,
              hasOneProvenTrailingAddition(in: evidence),
              canonicalSourceProvesTrailingAddition(
                  canonicalSource,
                  originalCount: evidence.declaration.count
              ) else {
            return text
        }

        let replacement: String
        switch evidence.declaration.style {
        case .arabic:
            replacement = String(evidence.listCount)
        case .chinese:
            guard let chinese = chineseNumber(evidence.listCount) else { return text }
            replacement = chinese
        }

        var result = evidence.normalizedText
        result.replaceSubrange(evidence.declaration.numberRange, with: replacement)
        return result
    }

    /// 返回紧邻列表的标题行中，唯一显式总数声明是否与实际列表项数一致。
    /// 编号列表与项目符号列表都支持；更早正文里的数字、列表项中的引号、
    /// 示例、命令和列表后的收束段不影响判断。没有显式声明或没有可识别列表时
    /// 返回 `nil`；标题行中有多个声明时返回 `false`。
    static func declaredCountMatchesList(in text: String) -> Bool? {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        guard let structure = consistencyListStructure(in: normalized) else {
            return nil
        }
        let lines = normalized.components(separatedBy: "\n")
        guard let headerLine = lines[..<structure.firstListLineIndex]
            .last(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
            return nil
        }
        let declarations = declaredCounts(in: headerLine)
        guard !declarations.isEmpty else { return nil }
        guard declarations.count == 1, let declaration = declarations.first else {
            return false
        }
        return declaration.count == structure.count
    }

    /// 只为事实校验生成逆投影。来源必须证明“原 N 项 + 尾随新增 1 项”，
    /// 候选必须证明自己是连续 N+1 项且声明已同步；验证通过后，仅把列表头的
    /// 唯一声明临时还原为 N。事实提取仍会看到正文中的所有普通数字、金额、
    /// 日期等，因此不会把总数同步豁免扩散到其他事实。
    static func projectedTextForFactValidation(
        in candidate: String,
        canonicalSource: String
    ) -> String? {
        let normalizedCandidate = VoicePolishCharacterSafety
            .normalizedLineEndings(candidate)
        guard normalizedCandidate == candidate,
              let evidence = synchronizationEvidence(in: normalizedCandidate),
              evidence.declaration.count == evidence.listCount,
              evidence.listCount >= 2 else {
            return nil
        }

        let originalCount = evidence.listCount - 1
        guard hasOneProvenTrailingAddition(in: evidence),
              canonicalSourceProvesTrailingAddition(
                  canonicalSource,
                  originalCount: originalCount
              ),
              let originalDeclarationText = renderedCount(
                  originalCount,
                  style: evidence.declaration.style
              ) else {
            return nil
        }

        // 反向构造同步前候选，再走正式同步函数复验；只有该函数能精确还原当前
        // 候选时，才证明变化确实只有列表头中的 N -> N+1。
        var candidateBeforeSynchronization = normalizedCandidate
        candidateBeforeSynchronization.replaceSubrange(
            evidence.declaration.numberRange,
            with: originalDeclarationText
        )
        guard synchronizeDeclaredCountForProvenTrailingAddition(
            in: candidateBeforeSynchronization,
            canonicalSource: canonicalSource
        ) == normalizedCandidate else {
            return nil
        }
        return candidateBeforeSynchronization
    }
}

private extension VoicePolishListCountConsistency {
    enum NumberStyle {
        case arabic
        case chinese
    }

    struct Declaration {
        let numberRange: Range<String.Index>
        let count: Int
        let style: NumberStyle
    }

    struct Evidence {
        let normalizedText: String
        let declaration: Declaration
        let listCount: Int
        let lastListItem: String
    }

    struct ConsistencyListStructure {
        let count: Int
        let firstListLineIndex: Int
    }

    struct IncrementMention {
        let count: Int
        let range: Range<String.Index>
    }

    struct OrdinalMarker {
        let ordinal: Int
        let range: Range<String.Index>
    }

    static func synchronizationEvidence(in text: String) -> Evidence? {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let numberedCount = VoicePolishNumbering.listItemCount(
            in: normalized,
            kind: .numberedList
        )
        let bulletCount = VoicePolishNumbering.listItemCount(
            in: normalized,
            kind: .bulletList
        )
        guard (numberedCount >= 2) != (bulletCount >= 2) else { return nil }
        let listCount = max(numberedCount, bulletCount)
        guard listCount >= 2,
              VoicePolishNumbering.recognizedListItemCount(in: normalized) == listCount else {
            return nil
        }

        let stripped = numberedCount >= 2
            ? VoicePolishNumbering.removingContinuousNumberedLineMarkers(in: normalized)
            : VoicePolishNumbering.removingProvenBulletLineMarkers(in: normalized)
        let originalLines = normalized.components(separatedBy: "\n")
        let strippedLines = stripped.components(separatedBy: "\n")
        guard originalLines.count == strippedLines.count else { return nil }
        let listLineIndices = originalLines.indices.filter {
            originalLines[$0] != strippedLines[$0]
        }
        guard listLineIndices.count == listCount,
              let firstListLineIndex = listLineIndices.first,
              let lastListLineIndex = listLineIndices.last,
              listBlockIsContiguous(
                  lines: originalLines,
                  listLineIndices: listLineIndices,
                  first: firstListLineIndex,
                  last: lastListLineIndex
              ),
              originalLines.dropFirst(lastListLineIndex + 1).allSatisfy({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }

        let declarations = declaredCounts(in: normalized)
        guard declarations.count == 1,
              let declaration = declarations.first,
              declaration.numberRange.lowerBound < lineStart(
                  at: firstListLineIndex,
                  in: normalized
              ) else {
            return nil
        }

        return Evidence(
            normalizedText: normalized,
            declaration: declaration,
            listCount: listCount,
            lastListItem: strippedLines[lastListLineIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func consistencyListStructure(
        in text: String
    ) -> ConsistencyListStructure? {
        let numberedCount = VoicePolishNumbering.listItemCount(
            in: text,
            kind: .numberedList
        )
        let bulletCount = VoicePolishNumbering.listItemCount(
            in: text,
            kind: .bulletList
        )
        guard (numberedCount >= 2) != (bulletCount >= 2) else { return nil }

        let count: Int
        let stripped: String
        if numberedCount >= 2 {
            count = numberedCount
            stripped = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                in: text
            )
        } else {
            count = bulletCount
            stripped = VoicePolishNumbering.removingProvenBulletLineMarkers(in: text)
        }

        let originalLines = text.components(separatedBy: "\n")
        let strippedLines = stripped.components(separatedBy: "\n")
        guard originalLines.count == strippedLines.count else { return nil }
        let listLineIndices = originalLines.indices.filter {
            originalLines[$0] != strippedLines[$0]
        }
        guard listLineIndices.count == count,
              let first = listLineIndices.first else {
            return nil
        }
        return ConsistencyListStructure(count: count, firstListLineIndex: first)
    }

    static func canonicalSourceProvesTrailingAddition(
        _ source: String,
        originalCount: Int
    ) -> Bool {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(source)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsLeadingExampleRisk(normalized) else {
            return false
        }

        let declarations = declaredCounts(in: normalized)
        guard declarations.count == 1,
              let declaration = declarations.first,
              declaration.count == originalCount else {
            return false
        }

        // canonical 本身已经是排好版的 N+1 项列表时，复用同一套严格证据。
        if let formatted = synchronizationEvidence(in: normalized),
           formatted.declaration.count == originalCount,
           formatted.listCount == originalCount + 1,
           hasOneProvenTrailingAddition(in: formatted) {
            return true
        }

        let increments = incrementMentions(in: normalized)
        guard increments.count == 1,
              let increment = increments.first,
              increment.count == 1,
              sourceAdditionIsTrailing(increment, in: normalized),
              !containsCodeOrCommandRisk(String(normalized[increment.range.lowerBound...])),
              !hasCancellation(after: increment.range, in: normalized) else {
            return false
        }

        if inlineParallelItemsProveOriginalCount(
            in: normalized,
            declaration: declaration,
            increment: increment
        ) {
            return true
        }

        for markers in inlineOrdinalMarkerCandidates(in: normalized) {
            guard markerSequenceIsValid(markers),
                  markers.count == originalCount,
                  let first = markers.first,
                  let last = markers.last,
                  declaration.numberRange.lowerBound < first.range.lowerBound,
                  increment.range.lowerBound > last.range.upperBound else {
                continue
            }
            return true
        }
        return false
    }

    /// canonical source 可能保留为口语的一行并列项，而候选已经排成列表。
    /// 仅接受“短且安全的计数标题：恰好 N 个并列项。尾随明确 +1”这一种形态。
    static func inlineParallelItemsProveOriginalCount(
        in source: String,
        declaration: Declaration,
        increment: IncrementMention
    ) -> Bool {
        guard declaration.count >= 2 else { return false }

        let sentenceBoundaries = "。！？!?；;\n"
        let beforeIncrement = source[..<increment.range.lowerBound]
        guard let additionBoundary = beforeIncrement.lastIndex(where: {
            sentenceBoundaries.contains($0)
        }) else {
            return false
        }

        // 换行也可作为追加句边界；若换行前已有句号，真正的原列表句应止于句号。
        var statementTerminator = additionBoundary
        if source[additionBoundary] == "\n" {
            var cursor = additionBoundary
            while cursor > source.startIndex {
                let previous = source.index(before: cursor)
                if source[previous].isWhitespace {
                    cursor = previous
                    continue
                }
                if "。！？!?；;".contains(source[previous]) {
                    statementTerminator = previous
                }
                break
            }
        }

        let precedingText = source[..<statementTerminator]
        let previousBoundary = precedingText.lastIndex(where: {
            sentenceBoundaries.contains($0)
        })
        let statementStart: String.Index
        if let previousBoundary {
            statementStart = source.index(after: previousBoundary)
        } else {
            statementStart = source.startIndex
        }
        guard declaration.numberRange.lowerBound >= statementStart,
              declaration.numberRange.upperBound <= statementTerminator else {
            return false
        }

        let statement = source[statementStart..<statementTerminator]
        let colons = statement.indices.filter { source[$0] == "：" || source[$0] == ":" }
        guard colons.count == 1,
              let colon = colons.first,
              declaration.numberRange.upperBound < colon else {
            return false
        }

        let title = String(source[statementStart..<colon])
        let bodyStart = source.index(after: colon)
        let body = String(source[bodyStart..<statementTerminator])
        guard safeInlineCountTitle(title, expectedCount: declaration.count),
              parallelItemCount(in: body) == declaration.count else {
            return false
        }
        return true
    }

    static func safeInlineCountTitle(
        _ title: String,
        expectedCount: Int
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 32,
              !containsLeadingExampleRisk(trimmed),
              !containsCodeOrCommandRisk(trimmed),
              !["例如", "比如", "示例", "例子", "反例", "假设", "引用"]
                .contains(where: { trimmed.contains($0) }) else {
            return false
        }

        let count = #"(?:[1-9]\d?|[一二两三四五六七八九十]{1,3})"#
        let unit = #"(?:点|条|项|步|部分|方面|件事|个事(?:情|项)?|(?:个)?(?:问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项))"#
        let trigger = #"(?:一共|总共|共计|共有|主要有|主要讲|归纳为|总结成|需要做|要做|包括|包含|分为|分成|列出|整理出|有|共)"#
        let safePrefix = #"[^。！？!?；;：:，,、“”\"‘’'`()\[\]{}]{0,16}"#
        let safeSuffix = #"(?:待办|待办事项|要做|需要做|内容|清单|安排|计划|如下)?"#
        let pattern = #"^\s*"# + safePrefix + trigger + #"\s*"#
            + count + #"\s*"# + unit + #"\s*"# + safeSuffix + #"\s*$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }

        let declarations = declaredCounts(in: trimmed)
        return declarations.count == 1 && declarations[0].count == expectedCount
    }

    static func parallelItemCount(in body: String) -> Int? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsCodeOrCommandRisk(trimmed),
              trimmed.range(of: #"[\n\r：:。！？!?；;]"#, options: .regularExpression) == nil else {
            return nil
        }

        let unifiedSeparators = trimmed
            .replacingOccurrences(of: "，", with: "、")
            .replacingOccurrences(of: ",", with: "、")
        let items = unifiedSeparators.split(
            separator: "、",
            omittingEmptySubsequences: false
        )
        guard items.count >= 2,
              items.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }
        return items.count
    }

    static func listBlockIsContiguous(
        lines: [String],
        listLineIndices: [Int],
        first: Int,
        last: Int
    ) -> Bool {
        let listLines = Set(listLineIndices)
        return (first...last).allSatisfy { index in
            listLines.contains(index)
                || lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func declaredCounts(in text: String) -> [Declaration] {
        let count = #"([1-9]\d?|[一二两三四五六七八九十]{1,3})"#
        let unit = #"(?:点|条|项|步|部分|方面|件事|个事(?:情|项)?|(?:个)?(?:问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项))"#
        let patterns = [
            #"(?:一共|总共|共计|共有|主要有|主要讲|归纳为|总结成|需要做|要做|包括|包含|分为|分成|列出|整理出|有|共)\s*"#
                + count + #"\s*"# + unit,
            #"(?:^|[。！？!?\n])\s*"# + count + #"\s*"# + unit
                + #"(?:要做|需要做|是|包括|如下|[：:])"#,
        ]

        var declarations: [Declaration] = []
        var seenLocations: Set<Int> = []
        let incrementRanges = incrementMentions(in: text).map(\.range)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: fullRange) {
                guard match.numberOfRanges > 1,
                      let numberRange = Range(match.range(at: 1), in: text),
                      !incrementRanges.contains(where: { $0.contains(numberRange.lowerBound) }),
                      seenLocations.insert(match.range(at: 1).location).inserted,
                      let parsed = parseCount(String(text[numberRange])) else {
                    continue
                }
                declarations.append(Declaration(
                    numberRange: numberRange,
                    count: parsed.count,
                    style: parsed.style
                ))
            }
        }
        return declarations.sorted {
            $0.numberRange.lowerBound < $1.numberRange.lowerBound
        }
    }

    static func hasOneProvenTrailingAddition(in evidence: Evidence) -> Bool {
        let mentions = incrementMentions(in: evidence.normalizedText)
        let localMentions = incrementMentions(in: evidence.lastListItem)
        guard mentions.count == 1,
              mentions[0].count == 1,
              localMentions.count == 1,
              let localMention = localMentions.first,
              localMention.count == 1,
              positiveAdditionIsAtItemStart(
                  localMention,
                  in: evidence.lastListItem
              ),
              !containsCodeOrCommandRisk(evidence.lastListItem),
              !hasCancellation(after: localMention.range, in: evidence.lastListItem) else {
            return false
        }
        return true
    }

    static func incrementMentions(in text: String) -> [IncrementMention] {
        let action = #"(?:再(?:补充|加|增加)(?:上)?|(?:另外|此外)?还有|另有|另(?:外)?|额外(?:增加|补充)?|加上)"#
        let unit = #"(?:个(?:事(?:情|项)?|问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项)|件事|项|条|点|步|部分|方面)"#
        let pattern = action
            + #"\s*([一二两三四五六七八九十]|[1-9]\d?)\s*"# + unit
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 0), in: text),
                  let countRange = Range(match.range(at: 1), in: text),
                  let parsed = parseCount(String(text[countRange])) else {
                return nil
            }
            return IncrementMention(count: parsed.count, range: range)
        }
    }

    static func positiveAdditionIsAtItemStart(
        _ mention: IncrementMention,
        in item: String
    ) -> Bool {
        let prefix = item[..<mention.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return additionPrefixIsAllowed(prefix)
    }

    static func sourceAdditionIsTrailing(
        _ mention: IncrementMention,
        in source: String
    ) -> Bool {
        let beforeMention = source[..<mention.range.lowerBound]
        let boundaryCharacters = "。！？!?；;\n"
        guard let boundary = beforeMention.lastIndex(where: {
            boundaryCharacters.contains($0)
        }) else {
            return false
        }
        let prefixStart = source.index(after: boundary)
        let prefix = source[prefixStart..<mention.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return additionPrefixIsAllowed(prefix)
    }

    static func additionPrefixIsAllowed(_ prefix: String) -> Bool {
        let allowedPrefixes: Set<String> = [
            "", "哦", "噢", "哦，", "噢，", "哦,", "噢,", "对了", "对了，", "对了,",
            "还有", "还有，", "还有,",
        ]
        guard allowedPrefixes.contains(prefix) else { return false }

        let negativePrefixPatterns = ["不", "别", "勿", "不要", "不用", "取消"]
        return !negativePrefixPatterns.contains { prefix.contains($0) }
    }

    static func inlineOrdinalMarkerCandidates(in source: String) -> [[OrdinalMarker]] {
        [
            regexOrdinalMarkers(
                pattern: #"第([一二三四五六七八九十]{1,3}|\d+)(?:个|点|条|项|步|部分|方面)?(?:就是|是|[，、,:：.）)]|[ \t]+)"#,
                source: source
            ),
            regexOrdinalMarkers(
                pattern: #"(?<![零〇一二两三四五六七八九十百千万亿])([一二三四五六七八九十]{1,3})(?:是|[、.)）])"#,
                source: source
            ),
            regexOrdinalMarkers(
                pattern: #"(?m)^[ \t]*(\d{1,2})(?:[.、)）])[ \t]+"#,
                source: source
            ),
        ]
    }

    static func regexOrdinalMarkers(
        pattern: String,
        source: String
    ) -> [OrdinalMarker] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 0), in: source),
                  let ordinalRange = Range(match.range(at: 1), in: source),
                  let parsed = parseCount(String(source[ordinalRange])) else {
                return nil
            }
            return OrdinalMarker(ordinal: parsed.count, range: range)
        }
    }

    static func markerSequenceIsValid(_ markers: [OrdinalMarker]) -> Bool {
        guard markers.count >= 2 else { return false }
        return markers.enumerated().allSatisfy { offset, marker in
            marker.ordinal == offset + 1
        }
    }

    static func hasCancellation(
        after range: Range<String.Index>,
        in text: String
    ) -> Bool {
        let suffix = String(text[range.upperBound...])
        let boundary = #"[，,。！？!?；;]"#
        let patterns = [
            #"(?:^|"# + boundary
                + #")\s*(?:不对|说错了|算了|不算了?|不要了|不用了|别加了|作废|撤回)\s*(?:$|"#
                + boundary + #")"#,
            #"(?:取消|删除|删掉|去掉|撤回|作废)\s*(?:(?:这个|这次|刚才(?:的)?|该)?\s*(?:补充|新增|增加)|(?:这|该|最后)(?:一)?项(?:\s*(?:补充|新增|增加))?)\s*(?:$|"#
                + boundary + #")"#,
            #"(?:(?:这个|这次|刚才(?:的)?|该)\s*(?:补充|新增|增加)|(?:这|该|最后)(?:一)?项(?:\s*(?:补充|新增|增加))?)\s*(?:不算了?|不要了|不用了|作废|撤回)\s*(?:$|"#
                + boundary + #")"#,
            #"(?:别|不要|不用)\s*(?:再)?(?:加|补充|增加)(?:了|这项|这一项)?"#,
            #"(?:不是|并非)\s*(?:新增|补充|加)"#,
        ]
        return patterns.contains {
            suffix.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func containsLeadingExampleRisk(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:例如|比如|举例|示例|例子|错误示范|反例)\s*[：:，,]"#,
            options: .regularExpression
        ) != nil
    }

    static func containsCodeOrCommandRisk(_ text: String) -> Bool {
        let patterns = [
            #"```|`[^`\n]*`"#,
            #"(?:^|[\s：:])(?:~/|/)[^\s;；]+"#,
            #"[A-Za-z]:\\[^\s;；]+"#,
            #"\$[A-Za-z_{(]"#,
            #"&&|\|\||;;|=>|:=|[{}]"#,
            #"\b[A-Za-z_][A-Za-z0-9_]*\s*="#,
            #"\b[A-Za-z_][A-Za-z0-9_.]*\("#,
            #"(?i)(?:^|[;；\n]\s*|运行\s+)(?:(?:sudo|env|command|builtin|time)\s+)*(?:bash|zsh|sh|fish|echo|printf|cd|pwd|ls|cat|head|tail|grep|rg|sed|awk|find|xargs|curl|wget|git|npm|pnpm|yarn|bun|node|python3?|ruby|swift|cargo|docker|kubectl|brew|chmod|chown|cp|mv|mkdir|touch|open|defaults|launchctl|killall?)\b"#,
            #"(?:代码|命令|指令|脚本|终端)\s*(?:如下|包括|是|：|:)"#,
        ]
        return patterns.contains {
            text.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func parseCount(_ source: String) -> (count: Int, style: NumberStyle)? {
        if let value = Int(source), (1...99).contains(value) {
            return (value, .arabic)
        }
        guard let canonical = ProtectedFactExtractor.canonicalChineseNumber(source),
              let value = Int(canonical),
              (1...99).contains(value) else {
            return nil
        }
        return (value, .chinese)
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

    static func renderedCount(_ number: Int, style: NumberStyle) -> String? {
        switch style {
        case .arabic:
            guard (1...99).contains(number) else { return nil }
            return String(number)
        case .chinese:
            return chineseNumber(number)
        }
    }

    static func lineStart(at targetLine: Int, in text: String) -> String.Index {
        var line = 0
        var cursor = text.startIndex
        while line < targetLine, cursor < text.endIndex {
            if text[cursor] == "\n" { line += 1 }
            cursor = text.index(after: cursor)
        }
        return cursor
    }
}
