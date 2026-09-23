import Foundation

struct VoicePolishRouteDecision: Sendable, Equatable {
    let route: VoicePolishRoute
    let correctionCount: Int
    let factCandidateCount: Int
    let matchedSignalCategories: Set<String>
}
enum VoicePolishComplexityRouter {

    static let signalConfigurationVersion = 5

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
        let topicSwitch = VoicePolishLayoutExpectation.containsComplexTopicSwitchEvidence(
            in: source
        )
        let ambiguousEntity = containsAny(in: normalized, chinese: ambiguousEntitiesZH, english: ambiguousEntitiesEN)
        let aiConstraintCount = distinctMatchCount(
            in: normalized,
            chinese: aiConstraintsZH,
            english: aiConstraintsEN
        )
        let layoutExpectation = VoicePolishLayoutExpectation.infer(from: request)

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
        if layoutExpectation.kind != .sentence { categories.insert("layout_contract") }

        let isDeep = correctionCount >= 2
            || delayed
            || exclusion
            || countChange
            || topicSwitch
            || ambiguousEntity
            || (request.context.scene == .aiPrompt && aiConstraintCount >= 2)

        let listContractNeedsPlanner = (layoutExpectation.kind == .numberedList
                || layoutExpectation.kind == .bulletList)
            && !VoicePolishFallbackFormatter.canSafelySatisfyListLayout(
                source,
                expectation: layoutExpectation
            )

        // Provider 的切段数量和纯文本长度不代表需要 JSON 规划。能够由本地
        // Formatter 严格保真排版的列表继续保持一次 Fast；任何已形成列表契约、
        // 但本地无法证明可排版的文本统一交给 Structured，避免 Fast 失败后回退
        // 成一整段。
        let isStructured = correctionCount == 1
            || sideNote
            || listContractNeedsPlanner
            || factCandidates.count >= 9

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

    /// 将基础复杂度与用户选择的质量档位合并。基础判断始终保留在
    /// `detectedRoute`，这里仅决定实际执行路径，便于历史与试跑审计。
    static func executedRoute(
        for decision: VoicePolishRouteDecision,
        request: VoicePolishRequest
    ) -> VoicePolishRoute {
        switch request.qualityMode {
        case .light:
            return .fast
        case .standard:
            return .structured
        case .automatic:
            // 生产模式统一走可校验的纯文本成稿协议。真实 Provider 验收已经证明，
            // 同一批输入在 JSON Plan 协议下会因字段或格式漂移整段回退，尤其会让
            // 长文本和带改口的短文本直接退回原文。复杂度仍保留在 detectedRoute
            // 中用于诊断；长度预算、排版契约和修复规则继续按内容自动计算。
            return .fast
        case .fast, .balanced:
            // “快速”和默认“标准”都必须是一次成稿路径。复杂度仍记录在
            // detectedRoute 中供诊断，但不能让改口、长列表或主题切换自动升级为
            // 脆弱的 JSON Plan 协议，否则失败时既增加等待，又只能回退原转写。
            return .fast
        case .quality:
            if decision.route == .fast,
               decision.matchedSignalCategories.contains("enumeration") {
                // 用户主动选择“深度整理”时，显式枚举可进入深度成稿；默认档
                // 仍保持一次请求。
                return .deep
            }
            return decision.route
        }
    }

    static func containsExplicitExclusionSignal(_ text: String) -> Bool {
        containsAny(
            in: text.precomposedStringWithCompatibilityMapping.lowercased(),
            chinese: explicitExclusionsZH,
            english: explicitExclusionsEN
        )
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
