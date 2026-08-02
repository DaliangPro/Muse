import Foundation

struct VoicePolishCorrectionRecord: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let historyID: String
    let createdAt: Date
    let scene: WritingScene
    let sourceText: String
    let generatedText: String
    let correctedText: String
    let learnStyle: Bool
    let learnTerminology: Bool

    init(
        id: String,
        historyID: String,
        createdAt: Date,
        scene: WritingScene,
        sourceText: String,
        generatedText: String,
        correctedText: String,
        learnStyle: Bool = true,
        learnTerminology: Bool = true
    ) {
        self.id = id
        self.historyID = historyID
        self.createdAt = createdAt
        self.scene = scene
        self.sourceText = sourceText
        self.generatedText = generatedText
        self.correctedText = correctedText
        self.learnStyle = learnStyle
        self.learnTerminology = learnTerminology
    }

    private enum CodingKeys: String, CodingKey {
        case id, historyID, createdAt, scene, sourceText, generatedText, correctedText
        case learnStyle, learnTerminology
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            historyID: try container.decode(String.self, forKey: .historyID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            scene: try container.decode(WritingScene.self, forKey: .scene),
            sourceText: try container.decode(String.self, forKey: .sourceText),
            generatedText: try container.decode(String.self, forKey: .generatedText),
            correctedText: try container.decode(String.self, forKey: .correctedText),
            learnStyle: try container.decodeIfPresent(Bool.self, forKey: .learnStyle) ?? true,
            learnTerminology: try container.decodeIfPresent(Bool.self, forKey: .learnTerminology) ?? true
        )
    }
}

struct StyleProfile: Codable, Sendable, Equatable {
    let sampleCount: Int
    let brevity: Double
    let formality: Double
    let paragraphing: Double
    let listPreference: Double
    let punctuationDensity: Double

    static func merging(global: StyleProfile, scene: StyleProfile) -> StyleProfile {
        StyleProfile(
            sampleCount: global.sampleCount + scene.sampleCount,
            brevity: global.brevity * 0.4 + scene.brevity * 0.6,
            formality: global.formality * 0.4 + scene.formality * 0.6,
            paragraphing: global.paragraphing * 0.4 + scene.paragraphing * 0.6,
            listPreference: global.listPreference * 0.4 + scene.listPreference * 0.6,
            punctuationDensity: global.punctuationDensity * 0.4 + scene.punctuationDensity * 0.6
        )
    }
}

struct AutomaticLexiconCandidate: Identifiable, Sendable, Equatable {
    var id: String { "\(alias.lowercased())→\(canonical.lowercased())" }
    let alias: String
    let canonical: String
    let occurrenceCount: Int
}

struct TerminologyCorrectionCandidate: Sendable, Equatable {
    let alias: String
    let canonical: String
}

/// 从一次用户明确纠正中提取术语候选。该纯函数同时供历史学习和统一术语仓库
/// 使用，避免两条链路分别实现文本 diff 后产生不一致。
enum TerminologyCorrectionExtractor {
    private struct LearningToken {
        let text: String
        let range: Range<String.Index>
    }

    /// 通过 token LCS 提取用户明确改动的最小连续片段。与逐 token zip 不同，
    /// 这里允许多个识别 token 对应一个标准术语（例如 Type less → Typeless）。
    static func candidates(
        generatedText: String,
        correctedText: String
    ) -> [TerminologyCorrectionCandidate] {
        let generated = learningTokens(in: generatedText)
        let corrected = learningTokens(in: correctedText)
        guard !generated.isEmpty, !corrected.isEmpty else { return [] }

        // 历史纠正通常是短文本。为避免对异常长文做二次方矩阵计算，长样本
        // 仍可参与风格画像，但不从中自动抽取术语。
        let maximumTokens = 256
        guard generated.count <= maximumTokens, corrected.count <= maximumTokens else { return [] }

        let matches = longestCommonSubsequenceMatches(generated, corrected)
        var changes: [TerminologyCorrectionCandidate] = []
        var previousGenerated = -1
        var previousCorrected = -1
        for (nextGenerated, nextCorrected) in matches + [(generated.count, corrected.count)] {
            let generatedRange = (previousGenerated + 1)..<nextGenerated
            let correctedRange = (previousCorrected + 1)..<nextCorrected
            previousGenerated = nextGenerated
            previousCorrected = nextCorrected

            guard !generatedRange.isEmpty, !correctedRange.isEmpty,
                  generatedRange.count <= 4, correctedRange.count <= 4 else { continue }
            let alias = sourceSpan(
                in: generatedText,
                tokens: generated,
                tokenRange: generatedRange
            )
            let canonical = sourceSpan(
                in: correctedText,
                tokens: corrected,
                tokenRange: correctedRange
            )
            guard isUsableLexiconChange(alias: alias, canonical: canonical) else { continue }
            changes.append(TerminologyCorrectionCandidate(
                alias: alias,
                canonical: canonical
            ))
        }
        return changes
    }

    private static func longestCommonSubsequenceMatches(
        _ left: [LearningToken],
        _ right: [LearningToken]
    ) -> [(Int, Int)] {
        let columns = right.count + 1
        var lengths = Array(repeating: 0, count: (left.count + 1) * columns)
        func offset(_ leftIndex: Int, _ rightIndex: Int) -> Int {
            leftIndex * columns + rightIndex
        }

        for leftIndex in stride(from: left.count - 1, through: 0, by: -1) {
            for rightIndex in stride(from: right.count - 1, through: 0, by: -1) {
                if tokenComparisonKey(left[leftIndex].text) == tokenComparisonKey(right[rightIndex].text) {
                    lengths[offset(leftIndex, rightIndex)] = 1
                        + lengths[offset(leftIndex + 1, rightIndex + 1)]
                } else {
                    lengths[offset(leftIndex, rightIndex)] = max(
                        lengths[offset(leftIndex + 1, rightIndex)],
                        lengths[offset(leftIndex, rightIndex + 1)]
                    )
                }
            }
        }

        var result: [(Int, Int)] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count, rightIndex < right.count {
            if tokenComparisonKey(left[leftIndex].text) == tokenComparisonKey(right[rightIndex].text) {
                result.append((leftIndex, rightIndex))
                leftIndex += 1
                rightIndex += 1
            } else if lengths[offset(leftIndex + 1, rightIndex)]
                >= lengths[offset(leftIndex, rightIndex + 1)] {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }
        return result
    }

    private static func learningTokens(in text: String) -> [LearningToken] {
        var result: [LearningToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character.isPunctuation {
                index = text.index(after: index)
                continue
            }
            if isASCIIWordCharacter(character) {
                let start = index
                index = text.index(after: index)
                while index < text.endIndex, isASCIIWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
                result.append(LearningToken(
                    text: String(text[start..<index]),
                    range: start..<index
                ))
            } else {
                let next = text.index(after: index)
                result.append(LearningToken(
                    text: String(text[index..<next]),
                    range: index..<next
                ))
                index = next
            }
        }
        return result
    }

    private static func sourceSpan(
        in text: String,
        tokens: [LearningToken],
        tokenRange: Range<Int>
    ) -> String {
        let start = tokens[tokenRange.lowerBound].range.lowerBound
        let end = tokens[tokenRange.upperBound - 1].range.upperBound
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsableLexiconChange(alias: String, canonical: String) -> Bool {
        guard (2...64).contains(alias.count),
              (2...64).contains(canonical.count),
              normalized(alias) != normalized(canonical),
              !alias.contains(where: { $0.isNewline }),
              !canonical.contains(where: { $0.isNewline }) else { return false }
        return true
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }

    private static func tokenComparisonKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }
}

enum StyleProfileUpdater {
    static let minimumGlobalSamples = 5
    static let minimumSceneSamples = 3
    static let sampleDecay = 0.92
    static let maximumAxisContribution = 0.10

    static func mergedProfile(
        from records: [VoicePolishCorrectionRecord],
        scene: WritingScene
    ) -> StyleProfile? {
        let styleRecords = records.filter(\.learnStyle)
        let global = styleRecords.count >= minimumGlobalSamples ? profile(from: styleRecords) : nil
        let sceneRecords = styleRecords.filter { $0.scene == scene }
        let sceneProfile = sceneRecords.count >= minimumSceneSamples ? profile(from: sceneRecords) : nil
        switch (global, sceneProfile) {
        case (.some(let global), .some(let sceneProfile)):
            return .merging(global: global, scene: sceneProfile)
        case (.some(let global), .none):
            return global
        case (.none, .some(let sceneProfile)):
            return sceneProfile
        case (.none, .none):
            return nil
        }
    }

    static func profile(from records: [VoicePolishCorrectionRecord]) -> StyleProfile {
        guard !records.isEmpty else {
            return StyleProfile(
                sampleCount: 0,
                brevity: 0,
                formality: 0,
                paragraphing: 0,
                listPreference: 0,
                punctuationDensity: 0
            )
        }
        let ordered = records.sorted { $0.createdAt < $1.createdAt }
        var totalWeight = 0.0
        var values = (brevity: 0.0, formality: 0.0, paragraphing: 0.0, list: 0.0, punctuation: 0.0)
        for (index, record) in ordered.enumerated() {
            let age = ordered.count - index - 1
            let weight = pow(sampleDecay, Double(age))
            let delta = featureDelta(record)
            totalWeight += weight
            values.brevity += delta.brevity * weight
            values.formality += delta.formality * weight
            values.paragraphing += delta.paragraphing * weight
            values.list += delta.list * weight
            values.punctuation += delta.punctuation * weight
        }
        let divisor = max(totalWeight, .leastNonzeroMagnitude)
        return StyleProfile(
            sampleCount: records.count,
            brevity: values.brevity / divisor,
            formality: values.formality / divisor,
            paragraphing: values.paragraphing / divisor,
            listPreference: values.list / divisor,
            punctuationDensity: values.punctuation / divisor
        )
    }

    static func lexiconCandidates(
        from records: [VoicePolishCorrectionRecord],
        minimumOccurrences: Int = 1
    ) -> [AutomaticLexiconCandidate] {
        var counts: [String: (alias: String, canonical: String, count: Int)] = [:]
        for record in records where record.learnTerminology {
            for candidate in TerminologyCorrectionExtractor.candidates(
                generatedText: record.generatedText,
                correctedText: record.correctedText
            ) {
                let key = "\(normalized(candidate.alias))→\(normalized(candidate.canonical))"
                let old = counts[key]
                counts[key] = (
                    candidate.alias,
                    candidate.canonical,
                    (old?.count ?? 0) + 1
                )
            }
        }
        let requiredOccurrences = max(1, minimumOccurrences)
        return counts.values
            .filter { $0.count >= requiredOccurrences }
            .map { AutomaticLexiconCandidate(
                alias: $0.alias,
                canonical: $0.canonical,
                occurrenceCount: $0.count
            ) }
            .sorted { left, right in
                if left.occurrenceCount != right.occurrenceCount {
                    return left.occurrenceCount > right.occurrenceCount
                }
                return left.alias < right.alias
            }
    }

    private static func featureDelta(
        _ record: VoicePolishCorrectionRecord
    ) -> (brevity: Double, formality: Double, paragraphing: Double, list: Double, punctuation: Double) {
        let generated = record.generatedText
        let corrected = record.correctedText
        let generatedCount = max(1, generated.count)
        let brevity = clamp(Double(generated.count - corrected.count) / Double(generatedCount))
        let formality = clamp(formalityScore(corrected) - formalityScore(generated))
        let paragraphing = clamp(Double(paragraphCount(corrected) - paragraphCount(generated)) / 4)
        let list = clamp(listScore(corrected) - listScore(generated))
        let punctuation = clamp(punctuationRatio(corrected) - punctuationRatio(generated))
        return (brevity, formality, paragraphing, list, punctuation)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -maximumAxisContribution), maximumAxisContribution)
    }

    private static func formalityScore(_ text: String) -> Double {
        let formal = ["请", "烦请", "敬请", "谢谢", "您好", "please", "thank you"]
        let casual = ["哈", "呀", "啦", "呗", "lol", "hey"]
        let normalizedText = normalized(text)
        return Double(formal.filter(normalizedText.contains).count
            - casual.filter(normalizedText.contains).count) / 10
    }

    private static func paragraphCount(_ text: String) -> Int {
        max(1, text.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count)
    }

    private static func listScore(_ text: String) -> Double {
        let lines = text.components(separatedBy: .newlines)
        let count = lines.filter {
            $0.range(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, options: .regularExpression) != nil
        }.count
        return min(1, Double(count) / 3)
    }

    private static func punctuationRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let punctuationCount = text.filter(\.isPunctuation).count
        return Double(punctuationCount) / Double(text.count)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }
}
