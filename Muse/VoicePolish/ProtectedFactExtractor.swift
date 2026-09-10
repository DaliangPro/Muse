import Foundation

enum ProtectedFactExtractor {

    struct FactLocation {
        let candidate: SourceFactCandidate
        let segmentIndex: Int
        let offset: Int
        let length: Int
    }

    private struct Pattern {
        let kind: ProtectedFactKind
        let expression: String
        let canonicalize: (String) -> String?
    }

    private static let patterns: [Pattern] = [
        Pattern(kind: .url, expression: #"https?://[^\s<>，。！？、；：,!?;]+"#, canonicalize: exact),
        Pattern(kind: .email, expression: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, canonicalize: lowercased),
        Pattern(kind: .command, expression: #"`[^`\n]+`"#, canonicalize: exact),
        Pattern(kind: .date, expression: #"(?<![A-Za-z0-9_])\d{4}(?:[-/.年])\d{1,2}(?:[-/.月])\d{1,2}日?(?![A-Za-z0-9_])"#, canonicalize: compactDate),
        Pattern(
            kind: .date,
            expression: #"(?:\d{1,2}|[零〇一二两三四五六七八九十]+)\s*月\s*(?:\d{1,2}|[零〇一二两三四五六七八九十]+)\s*日"#,
            canonicalize: compactMonthDay
        ),
        Pattern(
            kind: .time,
            expression: #"(?:(?:今天|明天|后天|(?:本|下)?周[一二三四五六日天]|星期[一二三四五六日天])\s*)?(?:凌晨|早上|上午|中午|下午|晚上|晚间)?\s*(?<!\d)(?:[01]?\d|2[0-3]):[0-5]\d\b"#,
            canonicalize: canonicalTime
        ),
        Pattern(
            kind: .time,
            expression: #"(?:(?:(?:今天|明天|后天|(?:本|下)?周[一二三四五六日天]|星期[一二三四五六日天])\s*(?:凌晨|早上|上午|中午|下午|晚上|晚间)?|(?:凌晨|早上|上午|中午|下午|晚上|晚间))\s*)(?:[01]?\d|2[0-3]|[零〇一二两三四五六七八九十]{1,3})\s*点(?:半|(?:[0-5]?\d|[零〇一二两三四五六七八九十]{1,3})\s*分)?"#,
            canonicalize: canonicalTime
        ),
        Pattern(
            kind: .time,
            // 明确带分钟的省略时间仍是时钟事实；“十点建议”没有分钟，
            // 不进入此规则。连续改口里的“十点半”不能因此消失。
            expression: #"(?:[01]?\d|2[0-3]|[零〇一二两三四五六七八九十]{1,3})\s*点(?:半|(?:[0-5]?\d|[零〇一二两三四五六七八九十]{1,3})\s*分)"#,
            canonicalize: canonicalTime
        ),
        Pattern(kind: .percentage, expression: #"[-+]?\d[\d,]*(?:\.\d+)?\s*%"#, canonicalize: canonicalPercentage),
        Pattern(
            kind: .percentage,
            expression: #"百分之[负零〇一二两三四五六七八九十百千万亿点]+"#,
            canonicalize: canonicalChinesePercentage
        ),
        Pattern(
            kind: .amount,
            expression: #"(?:(?:[¥￥$]|美元|人民币)\s*[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万|亿)?|[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万|亿|元|块|美元|人民币))"#,
            canonicalize: canonicalAmount
        ),
        Pattern(
            kind: .amount,
            expression: #"(?:[¥￥$]|美元|人民币)?\s*[负零〇一二两三四五六七八九十百千万亿点]+\s*(?:美元|人民币|元|块)"#,
            canonicalize: canonicalAmount
        ),
        Pattern(
            kind: .amount,
            expression: #"(?:合同)?(?:总)?金额(?:是|为)?\s*(?:[负零〇一二两三四五六七八九十百千万亿点]\s*)+"#,
            canonicalize: canonicalLabeledChineseAmount
        ),
        Pattern(
            kind: .amount,
            expression: #"(?:最终|最后|当前|原定)?(?:总)?(?:预算|报价|费用|成本)(?:先按|暂按|最终(?:是|为)?|是|为|定为|按)\s*(?:[-+]?\d[\d,]*(?:\.\d+)?|[负零〇一二两三四五六七八九十百千万亿点]+)"#,
            canonicalize: canonicalLabeledChineseAmount
        ),
        Pattern(kind: .version, expression: #"\bv?\d+(?:\.\d+){1,3}\b"#, canonicalize: lowercased),
        Pattern(
            kind: .filePath,
            // 无引号的相对路径只接受 ASCII 组件，否则“在Muse/...中记录”会
            // 把前后的中文叙述一起吞成路径。绝对路径和引号路径仍允许中文。
            expression: #"(?<![A-Za-z0-9._~-])(?:(?<=[“\"'])(?:~?/|\.\.?/)[^“”\"'\r\n]+(?=[”\"'])|(?:~?/|\.\.?/)(?:[\p{L}\p{N}._-]+/)*[\p{L}\p{N}._-]+|(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+)"#,
            canonicalize: exact
        ),
        Pattern(kind: .number, expression: #"[-+]?\d[\d,]*(?:\.\d+)?"#, canonicalize: canonicalNumber),
        Pattern(kind: .number, expression: #"[负零〇一二两双三四五六七八九十百千万亿点]+"#, canonicalize: canonicalChineseNumber),
        Pattern(kind: .quotedPhrase, expression: #"[“\"][^”\"\n]+[”\"]"#, canonicalize: exact),
        Pattern(kind: .codeIdentifier, expression: #"\b(?:[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*|[A-Za-z_][A-Za-z0-9_]*_[A-Za-z0-9_]+)\b"#, canonicalize: exact),
    ]

    static func extract(from segments: [RecognitionSegment]) -> [SourceFactCandidate] {
        var seen: Set<String> = []
        return extractedLocations(from: segments).map(\.candidate).filter { candidate in
            let semanticValue = candidate.canonicalValue ?? candidate.sourceText
            let key = "\(candidate.kind.rawValue)|\(semanticValue)|\(candidate.sourceSegmentIDs.sorted().joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    static func locations(
        of candidates: [SourceFactCandidate],
        in segments: [RecognitionSegment]
    ) -> [FactLocation] {
        // `extract` 会按语义去重，事实校验只需知道“这个值出现过”；改口定位
        // 则必须保留每一次出现的位置。例如“北京 3 人、上海 3 人……上海改
        // 4 人、北京仍 3 人”中，同一个 3 不能因为去重而只剩第一次位置。
        let keys = Set(candidates.map(locationKey))
        return extractedLocations(from: segments).filter { location in
            keys.contains(locationKey(location.candidate))
        }
    }

    private static func locationKey(_ candidate: SourceFactCandidate) -> String {
        let semanticValue = candidate.canonicalValue ?? candidate.sourceText
        return "\(candidate.kind.rawValue)|\(semanticValue)|\(candidate.sourceSegmentIDs.sorted().joined(separator: ","))"
    }

    private static func extractedLocations(
        from segments: [RecognitionSegment]
    ) -> [FactLocation] {
        var locations: [FactLocation] = []
        for (segmentIndex, segment) in segments.enumerated() {
            var occupied: [NSRange] = []
            let fullRange = NSRange(segment.text.startIndex..<segment.text.endIndex, in: segment.text)
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern.expression) else {
                    continue
                }
                for match in regex.matches(in: segment.text, range: fullRange) {
                    guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                          let range = Range(match.range, in: segment.text) else {
                        continue
                    }
                    let source = String(segment.text[range])
                    if pattern.kind == .amount, source.hasSuffix("块"),
                       segment.text[..<range.lowerBound].last.map({ "这那哪每".contains($0) }) == true {
                        continue
                    }
                    if pattern.kind == .number,
                       source.count == 1,
                       !isBoundedQuantity(numberRange: range, in: segment.text) {
                        continue
                    }
                    guard let canonical = pattern.canonicalize(source) else { continue }
                    locations.append(FactLocation(
                        candidate: SourceFactCandidate(
                            sourceText: source,
                            canonicalValue: canonical,
                            kind: pattern.kind,
                            sourceSegmentIDs: [segment.id]
                        ),
                        segmentIndex: segmentIndex,
                        offset: segment.text.distance(
                            from: segment.text.startIndex,
                            to: range.lowerBound
                        ),
                        length: source.count
                    ))
                    occupied.append(match.range)
                }
            }
        }
        return locations
    }

    static func canonicalValue(
        for source: String,
        kind: ProtectedFactKind
    ) -> String? {
        switch kind {
        case .number:
            return canonicalNumber(source) ?? canonicalChineseNumber(source)
        case .amount:
            return canonicalAmount(source) ?? canonicalLabeledChineseAmount(source)
        case .percentage:
            return canonicalPercentage(source) ?? canonicalChinesePercentage(source)
        case .date:
            return compactDate(source) ?? compactMonthDay(source)
        case .time:
            return canonicalTime(source)
        case .email:
            return lowercased(source)
        case .version:
            return lowercased(source)
        default:
            return exact(source)
        }
    }

    static func canonicalChineseNumber(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("负") {
            negative = true
            text.removeFirst()
        }

        let parts = text.split(separator: "点", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let integer = chineseInteger(String(parts[0])) else { return nil }
        var result = String(integer)
        if parts.count == 2 {
            let decimalDigits = parts[1].compactMap { chineseDigit($0) }
            guard decimalDigits.count == parts[1].count, !decimalDigits.isEmpty else { return nil }
            result += "." + decimalDigits.map(String.init).joined()
        }
        return negative ? "-" + result : result
    }

    private static func chineseInteger(_ text: String) -> Int64? {
        guard !text.isEmpty else { return 0 }
        let containsUnit = text.contains { "十百千万亿".contains($0) }
        if !containsUnit {
            let digits = text.compactMap(chineseDigit)
            guard digits.count == text.count else { return nil }
            return Int64(digits.map(String.init).joined())
        }

        var total: Int64 = 0
        var section: Int64 = 0
        var pendingDigit: Int64?
        var lastExplicitUnit: Int64?
        var zeroFillsOmittedUnits = false

        for character in text {
            if let digit = chineseDigit(character) {
                pendingDigit = Int64(digit)
                if digit == 0, lastExplicitUnit != nil {
                    zeroFillsOmittedUnits = true
                }
                continue
            }
            guard let unit = chineseUnit(character) else { return nil }
            if unit >= 10_000 {
                let base = section + (pendingDigit ?? (section == 0 ? 1 : 0))
                total += base * unit
                section = 0
                pendingDigit = nil
            } else {
                section += (pendingDigit ?? 1) * unit
                pendingDigit = nil
            }
            lastExplicitUnit = unit
            zeroFillsOmittedUnits = false
        }

        if let pendingDigit {
            if zeroFillsOmittedUnits {
                section += pendingDigit
            } else if let lastExplicitUnit, lastExplicitUnit >= 10 {
                section += pendingDigit * (lastExplicitUnit / 10)
            } else {
                section += pendingDigit
            }
        }
        return total + section
    }

    private static func chineseDigit(_ character: Character) -> Int? {
        switch character {
        case "零", "〇": return 0
        case "一": return 1
        case "二", "两", "双": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        default: return nil
        }
    }

    private static func chineseUnit(_ character: Character) -> Int64? {
        switch character {
        case "十": return 10
        case "百": return 100
        case "千": return 1_000
        case "万": return 10_000
        case "亿": return 100_000_000
        default: return nil
        }
    }

    private static func exact(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func lowercased(_ source: String) -> String? {
        exact(source)?.lowercased()
    }

    private static func canonicalNumber(_ source: String) -> String? {
        let value = source.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return NSDecimalNumber(decimal: decimal).stringValue
    }

    private static func canonicalAmount(_ source: String) -> String? {
        var value = source
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "人民币", with: "")
            .replacingOccurrences(of: "美元", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var multiplier = Decimal(1)
        if let chinese = canonicalChineseNumber(value) { return chinese }
        if value.hasSuffix("万") {
            multiplier = Decimal(10_000)
            value.removeLast()
        } else if value.hasSuffix("亿") {
            multiplier = Decimal(100_000_000)
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return NSDecimalNumber(decimal: decimal * multiplier).stringValue
    }

    private static func canonicalPercentage(_ source: String) -> String? {
        guard let number = canonicalNumber(source.replacingOccurrences(of: "%", with: "")) else {
            return nil
        }
        return number + "%"
    }

    private static func canonicalChinesePercentage(_ source: String) -> String? {
        guard source.hasPrefix("百分之"),
              let number = canonicalChineseNumber(String(source.dropFirst(3))) else {
            return nil
        }
        return number + "%"
    }

    private static func canonicalLabeledChineseAmount(_ source: String) -> String? {
        let compact = source.filter { !$0.isWhitespace }
        guard let range = compact.range(
            of: #"(?:[-+]?\d[\d,]*(?:\.\d+)?|[负零〇一二两三四五六七八九十百千万亿点]+)$"#,
            options: .regularExpression
        ) else { return nil }
        let value = String(compact[range])
        return canonicalNumber(value) ?? canonicalChineseNumber(value)
    }

    /// 将“10:00”“上午十点”统一为 24 小时时间；带相对日期或星期的口述
    /// 还会保留日期维度，例如“今天十点”与“明天十点”分别规范成
    /// `今天|10:00`、`明天|10:00`。不能只保留 HH:mm，否则模型把日期改掉
    /// 也会被事实门禁误认为等价。中文口述时间必须带明确时段、相对日期或
    /// 星期前缀才会被上面的模式提取，避免把“十点建议”误认成时钟事实。
    private static func canonicalTime(_ source: String) -> String? {
        let compact = source.filter { !$0.isWhitespace }
        if let colon = compact.firstIndex(of: ":") {
            let beforeColon = String(compact[..<colon])
            guard let hourRange = beforeColon.range(
                of: #"(?:[01]?\d|2[0-3])$"#,
                options: .regularExpression
            ) else { return nil }
            let hourText = String(beforeColon[hourRange])
            let minuteText = String(compact[compact.index(after: colon)...])
            guard let hour = Int(hourText), let minute = Int(minuteText),
                  (0...23).contains(hour), (0...59).contains(minute) else {
                return nil
            }
            let adjustedHour = adjustedClockHour(hour, in: compact)
            let clock = String(format: "%02d:%02d", adjustedHour, minute)
            return canonicalDayPrefix(in: compact).map { "\($0)|\(clock)" } ?? clock
        }

        guard let point = compact.firstIndex(of: "点") else { return nil }
        let beforePoint = String(compact[..<point])
        guard let hourRange = beforePoint.range(
            of: #"(?:\d{1,2}|[零〇一二两三四五六七八九十]{1,3})$"#,
            options: .regularExpression
        ) else { return nil }
        let hourText = String(beforePoint[hourRange])
        guard var hour = Int(hourText)
                ?? canonicalChineseNumber(hourText).flatMap(Int.init),
              (0...23).contains(hour) else {
            return nil
        }

        let afterPoint = String(compact[compact.index(after: point)...])
        let minute: Int
        if afterPoint.hasPrefix("半") {
            minute = 30
        } else if let minuteRange = afterPoint.range(
            of: #"^(?:\d{1,2}|[零〇一二两三四五六七八九十]{1,3})(?=分)"#,
            options: .regularExpression
        ) {
            let minuteText = String(afterPoint[minuteRange])
            guard let parsed = Int(minuteText)
                    ?? canonicalChineseNumber(minuteText).flatMap(Int.init),
                  (0...59).contains(parsed) else {
                return nil
            }
            minute = parsed
        } else {
            minute = 0
        }

        hour = adjustedClockHour(hour, in: compact)
        let clock = String(format: "%02d:%02d", hour, minute)
        return canonicalDayPrefix(in: compact).map { "\($0)|\(clock)" } ?? clock
    }

    private static func adjustedClockHour(_ rawHour: Int, in compact: String) -> Int {
        var hour = rawHour
        if ["下午", "晚上", "晚间"].contains(where: compact.contains), hour < 12 {
            hour += 12
        } else if compact.contains("凌晨"), hour == 12 {
            hour = 0
        } else if compact.contains("中午"), hour < 6 {
            hour += 12
        }
        return hour
    }

    private static func canonicalDayPrefix(in compact: String) -> String? {
        let patterns = [
            #"今天|明天|后天"#,
            #"(?:本|下)?周[一二三四五六日天]"#,
            #"星期[一二三四五六日天]"#,
        ]
        for pattern in patterns {
            guard let range = compact.range(of: pattern, options: .regularExpression) else {
                continue
            }
            var day = String(compact[range])
            day = day.replacingOccurrences(of: "星期", with: "周")
            if day.hasPrefix("本周") {
                day.removeFirst()
            }
            if day.hasSuffix("天"), day.contains("周") {
                day.removeLast()
                day.append("日")
            }
            return day
        }
        return nil
    }

    /// 单独的“九”“3”可能只是序号或噪声；紧邻明确量词时才升级为必须保留的
    /// 数量事实，覆盖“九个月”“3 个工作日”这类常见口述。
    private static func isBoundedQuantity(
        numberRange: Range<String.Index>,
        in text: String
    ) -> Bool {
        var unitStart = numberRange.upperBound
        while unitStart < text.endIndex, text[unitStart].isWhitespace {
            unitStart = text.index(after: unitStart)
        }
        let unitText = String(text[unitStart...].prefix(12))
            .filter { !$0.isWhitespace }
        let numberText = String(text[numberRange])
        let prefix = String(text[..<numberRange.lowerBound].suffix(2))
        // “任何一项/任一条”里的“一”是任指，不是数量为 1 的承诺。
        if numberText == "一", prefix.hasSuffix("任") || prefix.hasSuffix("任何") { return false }
        let units = [
            "个月", "月", "天", "年", "周", "小时", "分钟", "秒", "个工作日", "工作日",
            "条", "项", "款", "位", "名", "人", "个人", "个产品", "个渠道", "个问题", "个建议", "个版本",
            "个任务", "次", "遍", "轮",
        ]
        if ["次", "遍", "轮"].contains(where: unitText.hasPrefix) {
            let numberText = String(text[numberRange])
            let canonical = canonicalNumber(numberText) ?? canonicalChineseNumber(numberText)
            if canonical == "1" {
                let prefix = String(text[..<numberRange.lowerBound].suffix(12))
                    .filter { !$0.isWhitespace && !$0.isPunctuation }
                let explicitCountSignals = [
                    "共", "一共", "只有", "仅有", "只安排", "安排", "计划",
                    "最多", "最少", "上限", "下限", "次数", "轮次",
                ]
                return explicitCountSignals.contains(where: prefix.hasSuffix)
            }
        }
        if units.contains(where: unitText.hasPrefix) { return true }
        var labelEnd = numberRange.lowerBound
        while labelEnd > text.startIndex {
            let previous = text.index(before: labelEnd)
            guard text[previous].isWhitespace else { break }
            labelEnd = previous
        }
        let labelText = String(text[..<labelEnd].suffix(12))
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        let leadingQuantityLabels = [
            "人数为", "人数是", "人数有", "人数共", "人员为", "人员是",
            "名额为", "名额是", "数量为", "数量是",
        ]
        if leadingQuantityLabels.contains(where: labelText.hasSuffix) { return true }
        if numberText == "十",
           unitText.hasPrefix("个是") || unitText.hasPrefix("个为") {
            return true
        }
        let countedNouns = ["产品", "渠道", "问题", "建议", "版本"]
        guard unitText.hasPrefix("个") else { return false }
        // 允许“5 个主流产品”这类最多带四个中文修饰字的数量短语，但不要把
        // “一个 Swift 并发问题”中的不定冠词误当成受保护数字事实。
        return countedNouns.contains { noun in
            unitText.range(
                of: #"^个[\p{Han}]{0,4}"# + NSRegularExpression.escapedPattern(for: noun),
                options: .regularExpression
            ) != nil
        }
    }

    private static func compactDate(_ source: String) -> String? {
        let digits = source.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
        guard digits.count == 3,
              let year = Int(digits[0]),
              let month = Int(digits[1]),
              let day = Int(digits[2]),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func compactMonthDay(_ source: String) -> String? {
        let compact = source.filter { !$0.isWhitespace }
        guard let monthMarker = compact.firstIndex(of: "月"),
              let dayMarker = compact.firstIndex(of: "日"),
              monthMarker < dayMarker else { return nil }
        let monthText = String(compact[..<monthMarker])
        let dayText = String(compact[compact.index(after: monthMarker)..<dayMarker])
        func value(_ text: String) -> Int? {
            Int(text) ?? canonicalChineseNumber(text).flatMap(Int.init)
        }
        guard let month = value(monthText),
              let day = value(dayText),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        return String(format: "%02d-%02d", month, day)
    }
}
