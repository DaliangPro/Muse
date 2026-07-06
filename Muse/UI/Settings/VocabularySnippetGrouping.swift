struct VocabularySnippetGroup: Identifiable, Equatable {
    var id: String { replacement }
    let replacement: String
    let triggers: [String]
}

enum VocabularySnippetGrouping {
    static func groups(for snippets: [(trigger: String, value: String)]) -> [VocabularySnippetGroup] {
        var orderedReplacements: [String] = []
        var triggersByReplacement: [String: [String]] = [:]

        for snippet in snippets {
            if triggersByReplacement[snippet.value] == nil {
                orderedReplacements.append(snippet.value)
            }
            triggersByReplacement[snippet.value, default: []].append(snippet.trigger)
        }

        return orderedReplacements.map { replacement in
            VocabularySnippetGroup(
                replacement: replacement,
                triggers: triggersByReplacement[replacement, default: []]
            )
        }
    }
}
