import Foundation

enum ProtectedFactExtractor {

    private struct Pattern {
        let kind: ProtectedFactKind
        let expression: String
        let canonicalize: (String) -> String?
    }

    private static let patterns: [Pattern] = [
        Pattern(kind: .url, expression: #"https?://[^\s<>，。！？、；：,!?;]+"#, canonicalize: exact),
        Pattern(kind: .email, expression: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, canonicalize: lowercased),
        Pattern(kind: .command, expression: #"`[^`\n]+`"#, canonicalize: exact),
        Pattern(kind: .date, expression: #"\b\d{4}(?:[-/.年])\d{1,2}(?:[-/.月])\d{1,2}日?\b"#, canonicalize: compactDate),
        Pattern(kind: .time, expression: #"\b(?:[01]?\d|2[0-3]):[0-5]\d\b"#, canonicalize: exact),
        Pattern(kind: .percentage, expression: #"[-+]?\d[\d,]*(?:\.\d+)?\s*%"#, canonicalize: canonicalPercentage),
        Pattern(kind: .amount, expression: #"(?:[¥￥$]\s*)?[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万|亿|元|块|美元|人民币)"#, canonicalize: canonicalAmount),
        Pattern(kind: .version, expression: #"\bv?\d+(?:\.\d+){1,3}\b"#, canonicalize: lowercased),
        Pattern(kind: .filePath, expression: #"(?:~|/)(?:[^\s/]+/)*[^\s/]+"#, canonicalize: exact),
        Pattern(kind: .number, expression: #"[-+]?\d[\d,]*(?:\.\d+)?"#, canonicalize: canonicalNumber),
        Pattern(kind: .number, expression: #"[负零〇一二两三四五六七八九十百千万亿点]+"#, canonicalize: canonicalChineseNumber),
        Pattern(kind: .quotedPhrase, expression: #"[“\"][^”\"\n]+[”\"]"#, canonicalize: exact),
        Pattern(kind: .codeIdentifier, expression: #"\b(?:[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*|[A-Za-z_][A-Za-z0-9_]*_[A-Za-z0-9_]+)\b"#, canonicalize: exact),
    ]

    static func extract(from segments: [RecognitionSegment]) -> [SourceFactCandidate] {
        var candidates: [SourceFactCandidate] = []
        for segment in segments {
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
                    if pattern.kind == .number,
                       source.count == 1,
                       !"十百千万亿".contains(source) {
                        continue
                    }
                    guard let canonical = pattern.canonicalize(source) else { continue }
                    candidates.append(SourceFactCandidate(
                        sourceText: source,
                        canonicalValue: canonical,
                        kind: pattern.kind,
                        sourceSegmentIDs: [segment.id]
                    ))
                    occupied.append(match.range)
                }
            }
        }
        return candidates
    }

    static func canonicalValue(
        for source: String,
        kind: ProtectedFactKind
    ) -> String? {
        switch kind {
        case .number:
            return canonicalNumber(source) ?? canonicalChineseNumber(source)
        case .amount:
            return canonicalAmount(source)
        case .percentage:
            return canonicalPercentage(source)
        case .date:
            return compactDate(source)
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
        case "二", "两": return 2
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
}
