import Foundation

struct VoicePolishRouteDecision: Sendable, Equatable {
    let route: VoicePolishRoute
    let correctionCount: Int
    let factCandidateCount: Int
    let matchedSignalCategories: Set<String>
}
enum VoicePolishComplexityRouter {

    static let signalConfigurationVersion = 1

    private static let immediateCorrectionsZH = ["不对", "我改一下", "应该是", "我的意思是", "说错了"]
    private static let immediateCorrectionsEN = ["actually", "i mean", "let me correct that", "scratch that"]
    private static let delayedCorrectionsZH = ["前面那句改成", "刚才那句改成", "把开头改成", "最后还是", "最终决定"]
    private static let delayedCorrectionsEN = ["change the earlier part", "change what i said before", "final decision"]
    private static let explicitExclusionsZH = ["这句不用写", "不要放进正文", "这段删掉", "只是给你解释背景"]
    private static let explicitExclusionsEN = ["do not include this", "leave this out", "delete that part", "this is only background"]
    private static let sideNotesZH = ["顺便说一下", "插一句", "再补充一点"]
    private static let sideNotesEN = ["side note", "by the way", "one more note"]
    private static let countChangesZH = ["再加一件", "再减少一项", "不是三件是四件", "还有一项"]
    private static let countChangesEN = ["one more thing", "remove one item", "not three but four"]
    private static let enumerationsZH = ["第一", "第二", "第三", "首先", "其次", "最后"]
    private static let enumerationsEN = ["first", "second", "third", "firstly", "secondly"]
    private static let topicSwitchesZH = ["回到刚才", "换个话题", "另外一个问题", "先说另一件事"]
    private static let topicSwitchesEN = ["back to the earlier point", "different topic", "another issue"]
    private static let ambiguousEntitiesZH = ["那个谁", "叫什么来着", "具体名字忘了", "好像叫"]
    private static let ambiguousEntitiesEN = ["what was the name", "what is it called", "i forgot the name", "something like"]
    private static let aiConstraintsZH = ["要求", "必须", "不要", "输入", "输出格式", "限制", "条件"]
    private static let aiConstraintsEN = ["requirement", "must", "do not", "input", "output format", "constraint"]

    static func decide(
        request: VoicePolishRequest,
        factCandidates: [SourceFactCandidate]
    ) -> VoicePolishRouteDecision {
        let source = request.input.segments.map(\.text).joined(separator: "\n")
        let normalized = source.precomposedStringWithCompatibilityMapping.lowercased()
        let hasChinese = normalized.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
        let length = hasChinese ? normalized.count : englishWordCount(normalized)

        let correctionCount = countNonOverlapping(
            in: normalized,
            chinese: immediateCorrectionsZH,
            english: immediateCorrectionsEN
        )
        let delayed = containsAny(in: normalized, chinese: delayedCorrectionsZH, english: delayedCorrectionsEN)
        let exclusion = containsAny(in: normalized, chinese: explicitExclusionsZH, english: explicitExclusionsEN)
        let sideNote = containsAny(in: normalized, chinese: sideNotesZH, english: sideNotesEN)
        let countChange = containsAny(in: normalized, chinese: countChangesZH, english: countChangesEN)
        let enumeration = containsAny(in: normalized, chinese: enumerationsZH, english: enumerationsEN)
        let topicSwitch = containsAny(in: normalized, chinese: topicSwitchesZH, english: topicSwitchesEN)
        let ambiguousEntity = containsAny(in: normalized, chinese: ambiguousEntitiesZH, english: ambiguousEntitiesEN)
        let aiConstraintCount = distinctMatchCount(
            in: normalized,
            chinese: aiConstraintsZH,
            english: aiConstraintsEN
        )

        var categories: Set<String> = []
        if correctionCount > 0 { categories.insert("immediate_correction") }
        if delayed { categories.insert("delayed_correction") }
        if exclusion { categories.insert("explicit_exclusion") }
        if sideNote { categories.insert("side_note") }
        if countChange { categories.insert("count_change") }
        if enumeration { categories.insert("enumeration") }
        if topicSwitch { categories.insert("topic_switch") }
        if ambiguousEntity { categories.insert("ambiguous_entity") }
        if aiConstraintCount >= 2 { categories.insert("ai_constraints") }

        let isDeep = correctionCount >= 2
            || delayed
            || exclusion
            || countChange
            || topicSwitch
            || ambiguousEntity
            || factCandidates.count >= 16
            || (hasChinese ? length > 500 : length > 300)
            || (request.context.scene == .aiPrompt && aiConstraintCount >= 2)

        let isStructured = correctionCount == 1
            || sideNote
            || enumeration
            || factCandidates.count >= 9
            || request.input.segments.count > 1
            || (hasChinese ? length > 120 : length > 80)

        let route: VoicePolishRoute
        if isDeep {
            route = .deep
        } else if isStructured {
            route = .structured
        } else {
            route = .fast
        }

        return VoicePolishRouteDecision(
            route: route,
            correctionCount: correctionCount,
            factCandidateCount: factCandidates.count,
            matchedSignalCategories: categories
        )
    }

    static func containsExplicitExclusionSignal(_ text: String) -> Bool {
        containsAny(
            in: text.precomposedStringWithCompatibilityMapping.lowercased(),
            chinese: explicitExclusionsZH,
            english: explicitExclusionsEN
        )
    }

    private static func englishWordCount(_ text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.count
    }

    private static func containsAny(
        in text: String,
        chinese: [String],
        english: [String]
    ) -> Bool {
        chinese.contains { text.contains($0) }
            || english.contains { containsEnglishPhrase($0, in: text) }
    }

    private static func distinctMatchCount(
        in text: String,
        chinese: [String],
        english: [String]
    ) -> Int {
        chinese.filter { text.contains($0) }.count
            + english.filter { containsEnglishPhrase($0, in: text) }.count
    }

    private static func countNonOverlapping(
        in text: String,
        chinese: [String],
        english: [String]
    ) -> Int {
        let matches = (chinese + english)
            .sorted { $0.count > $1.count }
            .flatMap { phrase -> [Range<String.Index>] in
                if english.contains(phrase) {
                    return englishRanges(of: phrase, in: text)
                }
                var ranges: [Range<String.Index>] = []
                var cursor = text.startIndex
                while cursor < text.endIndex,
                      let range = text.range(of: phrase, range: cursor..<text.endIndex) {
                    ranges.append(range)
                    cursor = range.upperBound
                }
                return ranges
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        var accepted: [Range<String.Index>] = []
        for range in matches where !accepted.contains(where: { $0.overlaps(range) }) {
            accepted.append(range)
        }
        return accepted.count
    }

    private static func containsEnglishPhrase(_ phrase: String, in text: String) -> Bool {
        !englishRanges(of: phrase, in: text).isEmpty
    }

    private static func englishRanges(
        of phrase: String,
        in text: String
    ) -> [Range<String.Index>] {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])"
        ) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap {
            Range($0.range, in: text)
        }
    }
}
