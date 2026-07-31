import Foundation

enum EntityResolver {
    static let similarityThreshold = 0.88
    static let confidenceMargin = 0.08

    private struct Candidate: Sendable {
        let alias: String
        let canonical: String
        let source: EntityCandidateSource
    }

    static func resolve(
        segments: [RecognitionSegment],
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [ResolvedEntity] {
        let candidates = candidateList(
            lexicon: lexicon,
            snippets: snippets,
            hotwords: hotwords,
            context: context
        )
        var resolutions: [ResolvedEntity] = []
        var keys = Set<String>()

        for segment in segments {
            let exactCandidates = candidates.sorted { left, right in
                if left.source.priority != right.source.priority {
                    return left.source.priority > right.source.priority
                }
                return left.alias.count > right.alias.count
            }
            for candidate in exactCandidates
                where normalized(candidate.alias) != normalized(candidate.canonical)
                    && segment.text.contains(candidate.alias) {
                let key = "\(segment.id)|\(normalized(candidate.alias))|\(normalized(candidate.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: candidate.alias,
                    canonical: candidate.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: candidate.source,
                    confidence: 1
                ))
            }

            for token in tokens(in: segment.text) {
                guard let resolved = resolveSurface(token, candidates: candidates) else { continue }
                let key = "\(segment.id)|\(normalized(token))|\(normalized(resolved.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: token,
                    canonical: resolved.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: resolved.source,
                    confidence: resolved.score
                ))
            }
        }
        return resolutions
    }

    static func applying(_ resolutions: [ResolvedEntity], to text: String) -> String {
        var output = text
        for resolution in resolutions.sorted(by: { $0.surfaceText.count > $1.surfaceText.count }) {
            guard resolution.confidence >= similarityThreshold,
                  normalized(resolution.surfaceText) != normalized(resolution.canonical) else { continue }
            output = replacingLiteral(
                resolution.surfaceText,
                with: resolution.canonical,
                in: output
            )
        }
        return output
    }

    static func editSimilarity(_ left: String, _ right: String) -> Double {
        let a = Array(normalized(left))
        let b = Array(normalized(right))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...b.count)
        for (i, leftCharacter) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, rightCharacter) in b.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }

    private static func resolveSurface(
        _ surface: String,
        candidates: [Candidate]
    ) -> (canonical: String, source: EntityCandidateSource, score: Double)? {
        let ranked = candidates.map { candidate in
            (candidate: candidate, score: editSimilarity(surface, candidate.alias))
        }.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.candidate.source.priority > right.candidate.source.priority
        }
        guard let best = ranked.first, best.score >= similarityThreshold else { return nil }
        let competitor = ranked.first {
            normalized($0.candidate.canonical) != normalized(best.candidate.canonical)
        }
        guard competitor == nil || best.score - competitor!.score >= confidenceMargin else { return nil }
        return (best.candidate.canonical, best.candidate.source, best.score)
    }

    private static func candidateList(
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [Candidate] {
        var result: [Candidate] = []
        for entry in lexicon.entries where entry.isEnabled {
            result.append(Candidate(alias: entry.canonical, canonical: entry.canonical, source: .personalLexicon))
            result.append(contentsOf: entry.aliases.map {
                Candidate(alias: $0, canonical: entry.canonical, source: .personalLexicon)
            })
        }
        result.append(contentsOf: snippets.filter { !SnippetStorage.isDraftTrigger($0.trigger) }.map {
            Candidate(alias: $0.trigger, canonical: $0.value, source: .snippet)
        })
        result.append(contentsOf: hotwords.map {
            Candidate(alias: $0, canonical: $0, source: .hotword)
        })
        if context.safety == .safe, context.level != .metadataOnly {
            let body = [context.selectedText, context.textBeforeCursor, context.textAfterCursor]
                .compactMap { $0 }
                .joined(separator: " ")
            result.append(contentsOf: tokens(in: body).map {
                Candidate(alias: $0, canonical: $0, source: .authorizedContext)
            })
        }
        return deduplicated(result)
    }

    private static func tokens(in text: String) -> [String] {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.map(String.init).filter { (2...64).contains($0.count) }
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var bestByAlias: [String: Candidate] = [:]
        for candidate in candidates {
            let key = normalized(candidate.alias)
            guard !key.isEmpty else { continue }
            if let existing = bestByAlias[key], existing.source.priority >= candidate.source.priority {
                continue
            }
            bestByAlias[key] = candidate
        }
        return Array(bestByAlias.values)
    }

    private static func replacingLiteral(_ surface: String, with canonical: String, in text: String) -> String {
        guard !surface.isEmpty else { return text }
        return text.replacingOccurrences(
            of: surface,
            with: canonical,
            options: [.caseInsensitive],
            range: nil
        )
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }
}
