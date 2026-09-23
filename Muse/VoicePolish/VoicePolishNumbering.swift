import Foundation

/// Voice Polish 的确定性列表标记识别与格式标准化。
///
/// 这里只处理已经位于独立行首的显式列表标记，不按逗号、分号或语义猜测拆句，
/// 因此不会把普通整段内容擅自改造成列表。
enum VoicePolishNumbering {
    enum MarkerKind: Sendable, Equatable {
        case numbered
        case bullet
    }

    /// 按输出类型统计逐行列表项。编号列表兼容阿拉伯数字、括号数字和中文编号；
    /// 项目符号列表兼容常见 Markdown 与排版符号。
    static func listItemCount(in text: String, kind: OutputKind) -> Int {
        let recognized = parsedLines(in: text).compactMap { $0 }
        switch kind {
        case .numberedList:
            let numbered = recognized.filter { $0.kind == .numbered }
            guard numbered.count >= 2,
                  numbered.enumerated().allSatisfy({ offset, item in
                      item.ordinal == offset + 1
                  }) else {
                return 0
            }
            return numbered.count
        case .bulletList:
            let bullets = recognized.filter { $0.kind == .bullet }
            return bullets.count >= 2 ? bullets.count : 0
        case .sentence, .paragraphs:
            return 0
        }
    }

    /// 统计所有已显式逐行标记的项目，供成稿修复判断是否存在可安全标准化的列表。
    static func recognizedListItemCount(in text: String) -> Int {
        let recognized = parsedLines(in: text).compactMap { $0 }
        guard recognized.count >= 2,
              explicitMarkerSequenceIsSafe(recognized) else {
            return 0
        }
        return recognized.count
    }

    /// 是否存在行首疑似列表标记。它不代表标记已通过连续性校验，只用于避免把
    /// 错误码等可疑行继续当作“无标记行”二次重排。
    static func containsPotentialListMarker(in text: String) -> Bool {
        parsedLines(in: text).contains { $0 != nil }
    }

    /// 编号列表是否兑现本地推导出的可见编号偏好。混用中英文编号视为未兑现，
    /// 由 Repair 统一成一种风格；`.none` 仅用于非编号版式，始终通过。
    static func matchesNumberingPreference(
        in text: String,
        preference: VoicePolishNumberingPreference
    ) -> Bool {
        guard preference != .none else { return true }
        let recognized = parsedLines(in: text).compactMap { $0 }
        guard recognized.count >= 2,
              recognized.allSatisfy({ $0.kind == .numbered }) else {
            return false
        }
        return recognized.enumerated().allSatisfy { offset, item in
            item.numberingPreference == preference && item.ordinal == offset + 1
        }
    }

    /// 在受保护事实提取前，仅剥离可以证明为 `1...N` 的逐行编号标记。
    /// 年份、错误码、重复或乱序编号均原样保留，避免把事实误当成排版字符。
    static func removingContinuousNumberedLineMarkers(in text: String) -> String {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var lines = normalized.components(separatedBy: "\n")
        let parsed = lines.map(parseListLine)
        let numbered = parsed.compactMap { item -> ParsedItem? in
            guard item?.kind == .numbered else { return nil }
            return item
        }
        guard numbered.count >= 2,
              numbered.enumerated().allSatisfy({ offset, item in
                  item.ordinal == offset + 1
              }) else {
            return text
        }

        for index in lines.indices {
            guard let item = parsed[index], item.kind == .numbered else { continue }
            lines[index] = item.indentation + item.content
        }
        return lines.joined(separator: "\n")
    }

    /// 仅剥离能够由完整逐行结构证明为列表的原有标记。该接口用于安全等价校验：
    /// 连续编号或至少两条明确项目符号可以剥离；疑似负数、孤立标记和乱序编号保留。
    static func removingProvenListLineMarkers(in text: String) -> String {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var lines = normalized.components(separatedBy: "\n")
        let parsed = lines.map(parseListLine)
        let recognized = parsed.compactMap { $0 }
        guard recognized.count >= 2,
              explicitMarkerSequenceIsSafe(recognized) else {
            return text
        }

        for index in lines.indices {
            guard let item = parsed[index] else { continue }
            lines[index] = item.indentation + item.content
        }
        return lines.joined(separator: "\n")
    }

    /// 仅剥离经保守解析确认的项目符号，不会把以 `- 数字` 开头的负数行当列表。
    static func removingProvenBulletLineMarkers(in text: String) -> String {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var lines = normalized.components(separatedBy: "\n")
        let parsed = lines.map(parseListLine)
        let bullets = parsed.compactMap { item -> ParsedItem? in
            guard item?.kind == .bullet else { return nil }
            return item
        }
        guard bullets.count >= 2 else { return text }

        for index in lines.indices {
            guard let item = parsed[index], item.kind == .bullet else { continue }
            lines[index] = item.indentation + item.content
        }
        return lines.joined(separator: "\n")
    }

    /// 与单段文本版本相同，但允许一个连续列表跨越多个 ASR segment。只用于
    /// 事实抽取副本，原始/canonical 文本及 segment 身份都保持不变。
    static func removingContinuousNumberedLineMarkers(
        from segments: [RecognitionSegment]
    ) -> [RecognitionSegment] {
        let segmentLines = segments.map { segment in
            VoicePolishCharacterSafety.normalizedLineEndings(segment.text)
                .components(separatedBy: "\n")
        }
        let parsedLines = segmentLines.map { $0.map(parseListLine) }
        let numbered = parsedLines
            .flatMap { $0 }
            .compactMap { item -> ParsedItem? in
                guard item?.kind == .numbered else { return nil }
                return item
            }
        guard numbered.count >= 2,
              numbered.enumerated().allSatisfy({ offset, item in
                  item.ordinal == offset + 1
              }) else {
            return segments
        }

        return segments.enumerated().map { segmentIndex, segment in
            var lines = segmentLines[segmentIndex]
            for lineIndex in lines.indices {
                guard let item = parsedLines[segmentIndex][lineIndex],
                      item.kind == .numbered else { continue }
                lines[lineIndex] = item.indentation + item.content
            }
            return RecognitionSegment(
                id: segment.id,
                text: lines.joined(separator: "\n"),
                startTimeMs: segment.startTimeMs,
                endTimeMs: segment.endTimeMs,
                confidence: segment.confidence,
                isFinal: segment.isFinal
            )
        }
    }

    /// 将现有逐行列表统一为稳定格式。至少识别到两条独立列表行才会改写；
    /// 普通段落、单个疑似编号和每一项的正文内容均保持原样。
    ///
    /// - numberedList: `1. 内容`、`2. 内容`、`3. 内容`
    /// - bulletList: `- 内容`
    /// - sentence / paragraphs: 不做任何修改
    static func normalizeExistingList(in text: String, as kind: OutputKind) -> String {
        guard kind == .numberedList || kind == .bulletList else { return text }

        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var lines = normalized.components(separatedBy: "\n")
        let parsed = lines.map(parseListLine)
        let recognized = parsed.compactMap { $0 }
        guard recognized.count >= 2,
              explicitMarkerSequenceIsSafe(recognized) else {
            return text
        }

        var ordinal = 0
        for index in lines.indices {
            guard let item = parsed[index] else { continue }
            switch kind {
            case .numberedList:
                ordinal += 1
                lines[index] = "\(item.indentation)\(ordinal). \(item.content)"
            case .bulletList:
                lines[index] = "\(item.indentation)- \(item.content)"
            case .sentence, .paragraphs:
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension VoicePolishNumbering {
    struct ParsedItem: Sendable, Equatable {
        let kind: MarkerKind
        let indentation: String
        let content: String
        let numberingPreference: VoicePolishNumberingPreference?
        let ordinal: Int?
    }

    static let bulletCharacters: Set<Character> = [
        "-", "*", "•", "·", "▪", "◦", "‣", "–", "—",
    ]
    static let bulletsRequiringWhitespace: Set<Character> = ["-", "*", "–", "—"]
    static let arabicMarkerCharacters: Set<Character> = [".", ")", "）", "、", "．", "。"]
    static let decimalMarkerCharacters: Set<Character> = [".", "．"]
    static let chineseMarkerCharacters: Set<Character> = [
        "、", ".", "．", "。", ")", "）", ",", "，", ":", "：",
    ]
    static let chineseNumeralCharacters: Set<Character> = [
        "零", "〇", "一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "百",
    ]

    static func parsedLines(in text: String) -> [ParsedItem?] {
        VoicePolishCharacterSafety.normalizedLineEndings(text)
            .components(separatedBy: "\n")
            .map(parseListLine)
    }

    static func parseListLine(_ line: String) -> ParsedItem? {
        guard let contentStart = line.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let indentation = String(line[..<contentStart])
        let body = line[contentStart...]

        if let item = parseBullet(body, indentation: indentation) {
            return item
        }
        if let item = parseParenthesizedNumber(body, indentation: indentation) {
            return item
        }
        if let item = parseArabicNumber(body, indentation: indentation) {
            return item
        }
        return parseChineseNumber(body, indentation: indentation)
    }

    static func parseBullet(
        _ body: Substring,
        indentation: String
    ) -> ParsedItem? {
        guard let marker = body.first, bulletCharacters.contains(marker) else { return nil }
        let afterMarker = body.index(after: body.startIndex)
        if bulletsRequiringWhitespace.contains(marker),
           afterMarker < body.endIndex,
           !body[afterMarker].isWhitespace {
            return nil
        }
        if marker == "-", looksLikeSpacedNegativeFact(body[afterMarker...]) {
            return nil
        }
        return parsedItem(
            kind: .bullet,
            indentation: indentation,
            content: body[afterMarker...],
            numberingPreference: nil,
            ordinal: nil
        )
    }

    static func parseParenthesizedNumber(
        _ body: Substring,
        indentation: String
    ) -> ParsedItem? {
        guard let opening = body.first, opening == "(" || opening == "（" else { return nil }
        var cursor = body.index(after: body.startIndex)
        let numeralStart = cursor
        let preference: VoicePolishNumberingPreference
        let ordinal: Int
        if cursor < body.endIndex, isArabicDigit(body[cursor]) {
            while cursor < body.endIndex, isArabicDigit(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard let value = supportedArabicOrdinal(body[numeralStart..<cursor]) else {
                return nil
            }
            preference = .arabic
            ordinal = value
        } else {
            while cursor < body.endIndex, chineseNumeralCharacters.contains(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard let value = supportedChineseOrdinal(body[numeralStart..<cursor]) else {
                return nil
            }
            preference = .chinese
            ordinal = value
        }
        guard cursor < body.endIndex else { return nil }
        let closing = body[cursor]
        guard closing == ")" || closing == "）" else { return nil }
        cursor = body.index(after: cursor)
        return parsedItem(
            kind: .numbered,
            indentation: indentation,
            content: body[cursor...],
            numberingPreference: preference,
            ordinal: ordinal
        )
    }

    static func parseArabicNumber(
        _ body: Substring,
        indentation: String
    ) -> ParsedItem? {
        var cursor = body.startIndex
        let digitsStart = cursor
        while cursor < body.endIndex, isArabicDigit(body[cursor]) {
            cursor = body.index(after: cursor)
        }
        guard cursor > digitsStart, cursor < body.endIndex else { return nil }
        guard let ordinal = supportedArabicOrdinal(body[digitsStart..<cursor]) else { return nil }

        let marker = body[cursor]
        guard arabicMarkerCharacters.contains(marker) else { return nil }
        cursor = body.index(after: cursor)

        // `1.5 倍`、`2.0.1` 等数字事实不是列表标记。
        if decimalMarkerCharacters.contains(marker),
           cursor < body.endIndex,
           isArabicDigit(body[cursor]) {
            return nil
        }
        // ASCII 点号后紧跟字母、斜杠或 @ 更像裸域名、路径或邮箱片段，
        // 例如 `1.example.com`，不得为排版而插入空格破坏其可用性。
        if marker == ".",
           cursor < body.endIndex,
           !body[cursor].isWhitespace,
           isASCIIIdentifierOrAddressCharacter(body[cursor]) {
            return nil
        }
        return parsedItem(
            kind: .numbered,
            indentation: indentation,
            content: body[cursor...],
            numberingPreference: .arabic,
            ordinal: ordinal
        )
    }

    static func parseChineseNumber(
        _ body: Substring,
        indentation: String
    ) -> ParsedItem? {
        var cursor = body.startIndex
        let hasOrdinalPrefix = body[cursor] == "第"
        if hasOrdinalPrefix {
            cursor = body.index(after: cursor)
        }
        let numeralStart = cursor
        let ordinal: Int
        if hasOrdinalPrefix, cursor < body.endIndex, isArabicDigit(body[cursor]) {
            while cursor < body.endIndex, isArabicDigit(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard let value = supportedArabicOrdinal(body[numeralStart..<cursor]) else {
                return nil
            }
            ordinal = value
        } else {
            while cursor < body.endIndex, chineseNumeralCharacters.contains(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard let value = supportedChineseOrdinal(body[numeralStart..<cursor]) else {
                return nil
            }
            ordinal = value
        }
        guard cursor < body.endIndex else { return nil }

        let marker = body[cursor]
        guard marker == "是" || chineseMarkerCharacters.contains(marker) else { return nil }
        cursor = body.index(after: cursor)
        return parsedItem(
            kind: .numbered,
            indentation: indentation,
            content: body[cursor...],
            numberingPreference: .chinese,
            ordinal: ordinal
        )
    }

    static func parsedItem(
        kind: MarkerKind,
        indentation: String,
        content: Substring,
        numberingPreference: VoicePolishNumberingPreference?,
        ordinal: Int?
    ) -> ParsedItem? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return ParsedItem(
            kind: kind,
            indentation: indentation,
            content: trimmed,
            numberingPreference: numberingPreference,
            ordinal: ordinal
        )
    }

    static func isArabicDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    static func isASCIIIdentifierOrAddressCharacter(_ character: Character) -> Bool {
        (character >= "a" && character <= "z")
            || (character >= "A" && character <= "Z")
            || character == "/"
            || character == "@"
            || character == "_"
    }

    static func looksLikeSpacedNegativeFact(_ content: Substring) -> Bool {
        let value = content.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        // `- 5 kg` 与 `- 5元` 的负号语义完全相同，不能靠一个永远列不完的
        // 单位白名单猜测。只要短横线后的首个事实 token 是数字（可带货币符号、
        // 小数点或正号），就保守视为负数，而不是项目符号。
        return value.range(
            of: #"^(?:[$¥￥]\s*)?(?:\+\s*)?(?:\d|[.,]\d)"#,
            options: .regularExpression
        ) != nil
    }

    static func supportedArabicOrdinal(_ text: Substring) -> Int? {
        guard let value = Int(text), (1...99).contains(value) else { return nil }
        return value
    }

    static func supportedChineseOrdinal(_ text: Substring) -> Int? {
        guard !text.isEmpty,
              let canonical = ProtectedFactExtractor.canonicalChineseNumber(String(text)),
              let value = Int(canonical),
              (1...99).contains(value) else {
            return nil
        }
        return value
    }

    static func explicitMarkerSequenceIsSafe(_ items: [ParsedItem]) -> Bool {
        items.enumerated().allSatisfy { offset, item in
            guard item.kind == .numbered else { return true }
            return item.ordinal == offset + 1
        }
    }
}
