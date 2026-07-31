import Foundation

struct VoicePolishCorrectionRecord: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let historyID: String
    let createdAt: Date
    let scene: WritingScene
    let sourceText: String
    let generatedText: String
    let correctedText: String
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

enum StyleProfileUpdater {
    static let minimumGlobalSamples = 5
    static let minimumSceneSamples = 3
    static let sampleDecay = 0.92
    static let maximumAxisContribution = 0.10

    static func mergedProfile(
        from records: [VoicePolishCorrectionRecord],
        scene: WritingScene
    ) -> StyleProfile? {
        let global = records.count >= minimumGlobalSamples ? profile(from: records) : nil
        let sceneRecords = records.filter { $0.scene == scene }
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
        from records: [VoicePolishCorrectionRecord]
    ) -> [AutomaticLexiconCandidate] {
        var counts: [String: (alias: String, canonical: String, count: Int)] = [:]
        for record in records {
            let generated = tokens(record.generatedText)
            let corrected = tokens(record.correctedText)
            guard generated.count == corrected.count else { continue }
            for (alias, canonical) in zip(generated, corrected)
                where normalized(alias) != normalized(canonical)
                    && (2...64).contains(alias.count)
                    && (2...64).contains(canonical.count) {
                let key = "\(normalized(alias))→\(normalized(canonical))"
                let old = counts[key]
                counts[key] = (alias, canonical, (old?.count ?? 0) + 1)
            }
        }
        return counts.values
            .filter { $0.count >= 2 }
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

    private static func tokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }
}
