import Foundation

/// 修复 ASR 最常见、且能够在本地严格证明不改变正文字符的断句错误。
///
/// 这里只删除错误位置的标点或空白，不新增、删除、替换任何文字。复杂语病仍由
/// LLM 处理；本地规则只为“因为。”“同时它也。并没有……”这类明显残句兜底。
enum VoicePolishPunctuationRepair {
    enum Issue: String, Codable, Sendable, Equatable, CaseIterable {
        case cjkInnerSpace = "cjk_inner_space"
        case danglingConnector = "dangling_connector"
        case brokenPredicateBoundary = "broken_predicate_boundary"
    }

    private static let cjkInnerSpacePattern =
        #"(?<=[\p{Han}])[\t ]+(?=[\p{Han}])"#

    private static let danglingConnectorPattern =
        #"(^|[。！？!?；;\n])([ \t]*)(因为|所以|但是|可是|不过|而且|并且|同时|如果|虽然|由于|既然|然后|因此|另外|例如|比如|即)[，,]?[。！？!?]+(?:[ \t]*\n+[ \t]*|[ \t]*)(?=[^ \t\n])"#

    private static let brokenPredicatePattern =
        #"((?:同时|而且|并且)[^。！？!?；;\n]{1,24}(?:也|还|并|就|都|又|再|才|却|则|更|仍|只))[。！？!?]+(?:[ \t]*\n+[ \t]*|[ \t]*)(?=(?:(?:并|也|还|就|都|又|再|才|却|则|更|仍|只)?(?:不|没|未|无法|不能|不会|并未)))"#

    static func issues(in text: String) -> [Issue] {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var result: [Issue] = []
        if hasUnprotectedMatch(cjkInnerSpacePattern, in: normalized) {
            result.append(.cjkInnerSpace)
        }
        if hasUnprotectedMatch(danglingConnectorPattern, in: normalized) {
            result.append(.danglingConnector)
        }
        if hasUnprotectedMatch(brokenPredicatePattern, in: normalized) {
            result.append(.brokenPredicateBoundary)
        }
        return result
    }

    static func normalize(_ text: String) -> String {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
        var candidate = applying(
            cjkInnerSpacePattern,
            replacementTemplate: "",
            to: normalized
        )
        candidate = applying(
            danglingConnectorPattern,
            replacementTemplate: "$1$2$3",
            to: candidate
        )
        candidate = applying(
            brokenPredicatePattern,
            replacementTemplate: "$1",
            to: candidate
        )
        candidate = candidate.replacingOccurrences(
            of: #"\n[ \t]*\n(?:[ \t]*\n)+"#,
            with: "\n\n",
            options: .regularExpression
        )

        guard contentFingerprint(normalized) == contentFingerprint(candidate) else {
            return normalized
        }
        return candidate
    }
}

private extension VoicePolishPunctuationRepair {
    static func hasUnprotectedMatch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let protected = protectedRanges(in: text)
        return regex.matches(in: text, range: fullRange).contains { match in
            !overlapsProtectedRange(match.range, protected: protected)
        }
    }

    static func applying(
        _ pattern: String,
        replacementTemplate: String,
        to text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let protected = protectedRanges(in: text)
        let matches = regex.matches(in: text, range: fullRange).filter {
            !overlapsProtectedRange($0.range, protected: protected)
        }
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement = regex.replacementString(
                for: match,
                in: text,
                offset: 0,
                template: replacementTemplate
            )
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func protectedRanges(in text: String) -> [NSRange] {
        let patterns = [
            #"“[^”\r\n]*”"#,
            #"「[^」\r\n]*」"#,
            #"『[^』\r\n]*』"#,
            #"\"[^\"\r\n]*\""#,
            #"(?<![\p{L}\p{N}])'[^'\r\n]*'(?![\p{L}\p{N}])"#,
            #"`[^`\r\n]*`"#,
        ]
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: fullRange).map(\.range)
        }
    }

    static func overlapsProtectedRange(
        _ range: NSRange,
        protected: [NSRange]
    ) -> Bool {
        protected.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    static func contentFingerprint(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !$0.isPunctuation })
    }
}
