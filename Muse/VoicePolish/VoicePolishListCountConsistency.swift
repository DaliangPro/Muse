import Foundation

/// 对已经形成的列表校验总数，并在来源与成稿双重证据充分时同步声明。
///
/// 这里只允许改动唯一总数声明里的数字。列表正文、标点、空白及编号都不会变化；
/// 任何歧义、否定、引用、示例或代码风险都会让同步直接放弃。
enum VoicePolishListCountConsistency {
    struct PreservedDeclaredCountEvidence: Sendable, Equatable {
        let count: Int
        let sourceNumberText: String
        let candidateNumberTexts: Set<String>

        func satisfiesSourceFact(_ fact: SourceFactCandidate) -> Bool {
            fact.kind == .number
                && fact.canonicalValue == String(count)
                && fact.sourceText == sourceNumberText
        }

        func backsCandidateFact(_ fact: SourceFactCandidate) -> Bool {
            fact.kind == .number
                && fact.canonicalValue == String(count)
                && candidateNumberTexts.contains(fact.sourceText)
        }

        func satisfiesSourceFact(_ fact: ProtectedFact) -> Bool {
            fact.kind == .number
                && ProtectedFactExtractor.canonicalValue(
                    for: fact.sourceText,
                    kind: fact.kind
                ) == String(count)
                && fact.sourceText == sourceNumberText
        }
    }

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

    /// 来源把 N 作为清单总数声明，候选没有机械复述“共 N 项”，但已经用
    /// 顶层连续 `1...N` 完整表达时，总数事实仍然成立。这里不仅数编号：每一项
    /// 都必须有不同的短主题锚点，且这些锚点在来源中按同一顺序出现。来源各项
    /// 有可区分细节时，候选必须逐项保留；来源各项确实只有同一个共享谓词时，
    /// 候选也必须逐项完整保留该谓词。这样不会把“拆成 N 行”误当成“保留了
    /// N 项”，也不会放过复制某一项来凑数量。
    static func preservedDeclaredCountEvidence(
        in candidate: String,
        canonicalSource: String
    ) -> PreservedDeclaredCountEvidence? {
        let source = VoicePolishCharacterSafety
            .normalizedLineEndings(canonicalSource)
        let output = VoicePolishCharacterSafety
            .normalizedLineEndings(candidate)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let structure = consistencyListStructure(in: output),
              structure.kind == .numbered,
              structure.count >= 2,
              structure.items.count == structure.count,
              structure.isTopLevel else {
            return nil
        }

        let sourceDeclarations = structuralDeclaredCounts(in: source)
        guard sourceDeclarations.count == 1,
              let sourceDeclaration = sourceDeclarations.first,
              sourceDeclaration.count == structure.count,
              declarationIsAffirmative(sourceDeclaration, in: source),
              orderedDistinctAnchors(
                  from: structure.items,
                  around: sourceDeclaration,
                  in: source
              ) else {
            return nil
        }

        let lines = output.components(separatedBy: "\n")
        let header = lines[..<structure.firstListLineIndex]
            .joined(separator: "\n")
        let candidateDeclarations = structuralDeclaredCounts(in: header)
        let headlineCounts = headlineCountMentions(in: header)
        guard candidateDeclarations.allSatisfy({ $0.count == structure.count }),
              headlineCounts.allSatisfy({ $0 == structure.count }) else {
            return nil
        }

        return PreservedDeclaredCountEvidence(
            count: structure.count,
            sourceNumberText: String(source[sourceDeclaration.numberRange]),
            candidateNumberTexts: Set(candidateDeclarations.map {
                String(header[$0.numberRange])
            })
        )
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
        let kind: VoicePolishNumbering.MarkerKind
        let items: [String]
        let isTopLevel: Bool
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
        let kind: VoicePolishNumbering.MarkerKind
        let stripped: String
        if numberedCount >= 2 {
            count = numberedCount
            kind = .numbered
            stripped = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                in: text
            )
        } else {
            count = bulletCount
            kind = .bullet
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
        let items = listLineIndices.map {
            strippedLines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isTopLevel = listLineIndices.allSatisfy { index in
            originalLines[index].first.map { !$0.isWhitespace } == true
        }
        return ConsistencyListStructure(
            count: count,
            firstListLineIndex: first,
            kind: kind,
            items: items,
            isTopLevel: isTopLevel
        )
    }

    static func structuralDeclaredCounts(in text: String) -> [Declaration] {
        var declarations = declaredCounts(in: text)
        let count = #"([1-9]\d?|[一二两三四五六七八九十]{1,3})"#
        let unit = #"(?:点|条|项|步|部分|方面|件事|个事(?:情|项)?|(?:个)?(?:问题|原因|建议|方案|任务|风险|事项|要点|结论|观点|方法|要求|目标|主题|阶段|选择|选项))"#
        let suffix = #"(?:工作|内容|任务|事项|要点)?\s*(?:分别|逐项|各自|安排|清单|列表|如下|写清|列明|说明|整理)"#
        let pattern = #"(?:^|[。！？!?；;，,\n])\s*"# + count + #"\s*"#
            + unit + #"\s*"# + suffix
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return declarations
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let occupied = Set(declarations.map {
            NSRange($0.numberRange, in: text).location
        })
        for match in regex.matches(in: text, range: fullRange) {
            guard match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: text),
                  !occupied.contains(match.range(at: 1).location),
                  let parsed = parseCount(String(text[numberRange])) else {
                continue
            }
            declarations.append(Declaration(
                numberRange: numberRange,
                count: parsed.count,
                style: parsed.style
            ))
        }
        return declarations.sorted {
            $0.numberRange.lowerBound < $1.numberRange.lowerBound
        }
    }

    static func declarationIsAffirmative(
        _ declaration: Declaration,
        in text: String
    ) -> Bool {
        let clauseBoundaries = "。！？!?；;\n"
        let before = text[..<declaration.numberRange.lowerBound]
        let after = text[declaration.numberRange.upperBound...]
        let clauseStart = before.lastIndex(where: clauseBoundaries.contains)
            .map { text.index(after: $0) } ?? text.startIndex
        let clauseEnd = after.firstIndex(where: clauseBoundaries.contains)
            ?? text.endIndex
        // 无标点长口述可能在同一“句”里包含几十个清单项；后面某一项的
        // “如果遇到阻塞”不能反向把开头“下面共 N 项”判成假设。只检查声明
        // 附近的语用窗口，同时仍受真实句界约束。
        let localStart = text.index(
            declaration.numberRange.lowerBound,
            offsetBy: -min(48, text.distance(
                from: clauseStart,
                to: declaration.numberRange.lowerBound
            ))
        )
        let localEnd = text.index(
            declaration.numberRange.upperBound,
            offsetBy: min(24, text.distance(
                from: declaration.numberRange.upperBound,
                to: clauseEnd
            ))
        )
        let clause = String(text[localStart..<localEnd])
        let unsupported = [
            "例如", "比如", "举例", "示例", "反例", "假设", "假如", "如果",
            "有人说", "旧记录", "旧版本", "错误示范", "并非", "不代表",
        ]
        return !unsupported.contains(where: clause.contains)
    }

    static func orderedDistinctAnchors(
        from items: [String],
        around declaration: Declaration,
        in source: String
    ) -> Bool {
        let anchors = items.compactMap(subjectAnchor)
        guard anchors.count == items.count,
              Set(anchors).count == anchors.count else {
            return false
        }

        for region in declarationBoundRegions(
            around: declaration,
            in: source
        ) {
            let normalizedRegion = normalizedAnchorText(region)
            var cursor = normalizedRegion.startIndex
            var ranges: [Range<String.Index>] = []
            for anchor in anchors {
                guard let range = normalizedRegion.range(
                    of: anchor,
                    range: cursor..<normalizedRegion.endIndex
                ) else {
                    ranges = []
                    break
                }
                ranges.append(range)
                cursor = range.upperBound
            }
            guard ranges.count == anchors.count else { continue }
            let windows = items.indices.map { index in
                let upper = ranges.indices.contains(index + 1)
                    ? ranges[index + 1].lowerBound
                    : normalizedRegion.endIndex
                return String(normalizedRegion[ranges[index].lowerBound..<upper])
            }
            let detailsMatch = items.indices.allSatisfy { index in
                itemHasSourceBackedDetail(
                    items[index],
                    in: windows[index],
                    excluding: windows.enumerated().compactMap {
                        $0.offset == index ? nil : $0.element
                    }
                )
            }
            if detailsMatch || completeSharedPredicateMatches(
                items: items,
                anchors: anchors,
                sourceWindows: windows
            ) {
                return true
            }
        }
        return false
    }

    static func subjectAnchor(in item: String) -> String? {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^\*\*([^*\n]{2,48})\*\*\s*[：:]"#,
            #"^__([^_\n]{2,48})__\s*[：:]"#,
            #"^([^：:\n]{2,48})[：:]"#,
            #"^([^，,。；;\n]{2,24})[，,]"#,
            #"^(.{2,24}?)(?=(?:由|归|交给).{1,12}(?:负责|跟进|执行))"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: trimmed,
                      range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            let anchor = normalizedAnchorText(String(trimmed[range]))
            if (2...40).contains(anchor.count) {
                return anchor
            }
        }
        return nil
    }

    static func declarationBoundRegions(
        around declaration: Declaration,
        in source: String
    ) -> [String] {
        let barriers = [
            "旧记录", "旧版本", "错误记录", "无关", "另一个话题",
            "另一件事", "不是本次", "不属于本次", "以下仅为示例", "下面只是示例",
            "示例内容", "反例",
        ]
        let before = String(source[..<declaration.numberRange.lowerBound])
        let after = String(source[declaration.numberRange.upperBound...])

        let boundedBefore: String
        if let barrier = barriers.compactMap({ before.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }) {
            boundedBefore = String(before[barrier.upperBound...])
        } else {
            boundedBefore = before
        }

        let boundedAfter: String
        if let barrier = barriers.compactMap({ after.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            boundedAfter = String(after[..<barrier.lowerBound])
        } else {
            boundedAfter = after
        }
        // 声明既可能先总括再列内容，也可能在文末总结“以上六件事”。两侧分别
        // 验证，但不允许跨越旧记录、无关话题或示例边界拼接锚点。
        return [boundedAfter, boundedBefore].filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func itemHasSourceBackedDetail(
        _ item: String,
        in sourceWindow: String,
        excluding otherSourceWindows: [String]
    ) -> Bool {
        var normalizedItem = normalizedAnchorText(item)
        if let subject = subjectAnchor(in: item),
           let range = normalizedItem.range(of: subject) {
            normalizedItem.removeSubrange(range)
        }
        let stopTokens: Set<String> = [
            "负责", "完成", "安排", "确认", "整理", "要求", "需要", "进行", "相关",
            "当前", "工作", "内容", "事项", "时间", "之前", "之后", "最终", "跟进",
        ]
        var candidates: Set<String> = []
        let characters = Array(normalizedItem)
        if characters.count >= 2 {
            for length in 2...min(6, characters.count) {
                for start in 0...(characters.count - length) {
                    let token = String(characters[start..<(start + length)])
                    guard !stopTokens.contains(token),
                          token.unicodeScalars.contains(where: {
                            CharacterSet.alphanumerics.contains($0)
                                || (0x3400...0x9FFF).contains($0.value)
                          }) else { continue }
                    candidates.insert(token)
                }
            }
        }
        let normalizedSourceWindow = normalizedAnchorText(sourceWindow)
        let normalizedOtherWindows = otherSourceWindows.map(normalizedAnchorText)
        // 细节不仅要出现在当前主题的来源窗口，还必须能把当前项与其他来源项
        // 区分开。“负责人”“需要处理”等多项共有的通用词不能冒充每项细节；
        // 小陈、小林、产品组或各项独有的动作/时间仍可分别形成证明。
        return candidates.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left < right
        }.contains { token in
            normalizedSourceWindow.contains(token)
                && !normalizedOtherWindows.contains(where: { $0.contains(token) })
        }
    }

    /// 当各来源项除了主题锚点外完全相同时，它们没有可供逐项区分的额外细节。
    /// 此时允许“不同主题 + 同一完整谓词”共同证明列表结构；只要任一来源项有
    /// 独有细节，或任一候选项删改了共享谓词，就继续交给严格的独有细节规则。
    static func completeSharedPredicateMatches(
        items: [String],
        anchors: [String],
        sourceWindows: [String]
    ) -> Bool {
        guard items.count == anchors.count,
              sourceWindows.count == anchors.count else {
            return false
        }

        let sourcePredicates = sourceWindows.indices.compactMap { index in
            predicateRemainder(
                in: sourceWindows[index],
                removing: anchors[index]
            )
        }
        guard sourcePredicates.count == sourceWindows.count,
              let sharedPredicate = sourcePredicates.first,
              sharedPredicate.count >= 2,
              sourcePredicates.allSatisfy({ $0 == sharedPredicate }) else {
            return false
        }

        let candidatePredicates = items.indices.compactMap { index in
            predicateRemainder(in: items[index], removing: anchors[index])
        }
        return candidatePredicates.count == items.count
            && candidatePredicates.allSatisfy({ $0 == sharedPredicate })
    }

    static func predicateRemainder(
        in text: String,
        removing anchor: String
    ) -> String? {
        var normalized = normalizedAnchorText(text)
        guard let range = normalized.range(of: anchor) else { return nil }
        normalized.removeSubrange(range)
        return normalized.isEmpty ? nil : normalized
    }

    static func headlineCountMentions(in header: String) -> [Int] {
        let pattern = #"(?:总数|合计|数量|共计|一共|共有)\s*[：:为是]?\s*([1-9]\d?|[一二两三四五六七八九十]{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        return regex.matches(in: header, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: header) else {
                return nil
            }
            return parseCount(String(header[numberRange]))?.count
        }
    }

    static func normalizedAnchorText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation && $0 != "*" && $0 != "_" }
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
