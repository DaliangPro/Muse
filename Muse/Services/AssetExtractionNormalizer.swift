import Foundation

struct AssetExtractionNormalizer: Sendable {

    func normalizeCandidates(
        result: AssetExtractionResult,
        sourceRecords: [HistoryRecord],
        extractionJobID: String,
        existingKeys: Set<String> = []
    ) -> [LanguageAssetCandidateRecord] {
        let sourceRecordIDSet = Set(sourceRecords.map(\.id))
        let sourceTextByID = Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.id, $0.finalText) })
        let now = Date()
        // 跨任务防重②：seenKeys 以库内既有候选+资产的内容键打底，
        // 模型重复产出的内容不再二次入池
        var seenKeys = existingKeys
        var records: [LanguageAssetCandidateRecord] = []

        for candidate in result.assets.prefix(AssetExtractionNormalizationLimit.maxCandidates) {
            guard let type = candidate.type,
                  LanguageAssetType.creatorCases.contains(type),
                  let grade = candidate.grade
            else { continue }

            let sourceRecordIDs = candidate.sourceRecordIDs
                .filter { sourceRecordIDSet.contains($0) }
            let resolvedSourceIDs = unique(sourceRecordIDs)
            guard !resolvedSourceIDs.isEmpty else { continue }

            guard let content = sourceSupportedContent(
                for: candidate,
                sourceRecordIDs: resolvedSourceIDs,
                sourceTextByID: sourceTextByID
            ) else { continue }

            let title = normalizeOptionalText(candidate.title) ?? content
            let reason = normalizeOptionalText(candidate.reason)
                ?? normalizeOptionalText(candidate.summary)
                ?? L("命中新语料资产提炼规则", "Matched language asset extraction rules")
            guard !content.isEmpty, !title.isEmpty, !reason.isEmpty else { continue }

            let dedupeKey = "\(type.rawValue)|\(title.lowercased())|\(content.lowercased())"
            guard seenKeys.insert(dedupeKey).inserted else { continue }

            records.append(LanguageAssetCandidateRecord(
                id: UUID().uuidString,
                createdAt: now,
                updatedAt: now,
                assetType: type,
                grade: grade,
                title: title,
                content: content,
                summary: normalizeOptionalText(candidate.summary),
                reason: reason,
                scenes: normalizeStrings(candidate.scenes),
                audiences: normalizeStrings(candidate.audiences),
                ruleHit: normalizeOptionalText(candidate.ruleHit),
                sourceRecordIDs: resolvedSourceIDs,
                sourceRecordCount: resolvedSourceIDs.count,
                extractionJobID: extractionJobID,
                status: .pending
            ))
        }

        return records
    }

    private func sourceSupportedContent(
        for candidate: AssetExtractionCandidate,
        sourceRecordIDs: [String],
        sourceTextByID: [String: String]
    ) -> String? {
        let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSourceSupported(content, sourceRecordIDs: sourceRecordIDs, sourceTextByID: sourceTextByID) {
            return content
        }

        return nil
    }

    private func isSourceSupported(
        _ content: String,
        sourceRecordIDs: [String],
        sourceTextByID: [String: String]
    ) -> Bool {
        let candidate = canonical(content)
        guard candidate.count >= 3 else { return false }

        return sourceRecordIDs.contains { id in
            guard let sourceText = sourceTextByID[id] else { return false }
            return canonical(sourceText).contains(candidate)
        }
    }

    private func canonical(_ value: String) -> String {
        let scalars = value
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
        return String(String.UnicodeScalarView(scalars))
    }

    private func normalizeOptionalText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func normalizeStrings(_ values: [String]) -> [String] {
        unique(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private enum AssetExtractionNormalizationLimit {
    static let maxCandidates = 80
}
