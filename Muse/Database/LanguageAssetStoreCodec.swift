import Foundation
import SQLite3

struct LanguageAssetStoreCodec {
    private let iso = ISO8601DateFormatter()

    func decodeJob(from stmt: OpaquePointer?) -> AssetExtractionJob? {
        guard let rangeType = AssetExtractionRangeType(rawValue: SQL.column(stmt, 4)),
              let status = AssetExtractionJobStatus(rawValue: SQL.column(stmt, 7))
        else { return nil }

        return AssetExtractionJob(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            startedAt: SQL.optionalColumn(stmt, 2).flatMap { iso.date(from: $0) },
            finishedAt: SQL.optionalColumn(stmt, 3).flatMap { iso.date(from: $0) },
            rangeType: rangeType,
            rangePayload: SQL.optionalColumn(stmt, 5),
            sourceRecordCount: Int(sqlite3_column_int(stmt, 6)),
            status: status,
            summary: SQL.optionalColumn(stmt, 8),
            errorMessage: SQL.optionalColumn(stmt, 9)
        )
    }

    func decodeRecipe(from stmt: OpaquePointer?) -> ExtractionRecipe? {
        guard let outputKind = ExtractionOutputKind(rawValue: SQL.column(stmt, 6)),
              let processingStrategy = ExtractionProcessingStrategy(rawValue: SQL.column(stmt, 7)),
              let sourcePolicy = ExtractionSourcePolicy(rawValue: SQL.column(stmt, 8)),
              let destination = ExtractionDestination(rawValue: SQL.column(stmt, 11)),
              let status = ExtractionRecipeStatus(rawValue: SQL.column(stmt, 13))
        else { return nil }

        return ExtractionRecipe(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            updatedAt: iso.date(from: SQL.column(stmt, 2)) ?? Date(),
            name: SQL.column(stmt, 3),
            recipeDescription: SQL.column(stmt, 4),
            goalPrompt: SQL.column(stmt, 5),
            outputKind: outputKind,
            processingStrategy: processingStrategy,
            sourcePolicy: sourcePolicy,
            outputSchema: SQL.column(stmt, 9),
            qualityRules: SQL.column(stmt, 10),
            saveRule: SQL.optionalColumn(stmt, 14) ?? "",
            ignoreRule: SQL.optionalColumn(stmt, 15) ?? "",
            destination: destination,
            isBuiltIn: sqlite3_column_int(stmt, 12) == 1,
            status: status
        )
    }

    func decodeRun(from stmt: OpaquePointer?) -> ExtractionRun? {
        guard let rangeType = AssetExtractionRangeType(rawValue: SQL.column(stmt, 6)),
              let status = ExtractionRunStatus(rawValue: SQL.column(stmt, 9))
        else { return nil }

        return ExtractionRun(
            id: SQL.column(stmt, 0),
            recipeID: SQL.column(stmt, 1),
            recipeName: SQL.column(stmt, 2),
            createdAt: iso.date(from: SQL.column(stmt, 3)) ?? Date(),
            startedAt: SQL.optionalColumn(stmt, 4).flatMap { iso.date(from: $0) },
            finishedAt: SQL.optionalColumn(stmt, 5).flatMap { iso.date(from: $0) },
            rangeType: rangeType,
            rangePayload: SQL.optionalColumn(stmt, 7),
            sourceRecordCount: Int(sqlite3_column_int(stmt, 8)),
            status: status,
            resultCount: Int(sqlite3_column_int(stmt, 10)),
            summary: SQL.optionalColumn(stmt, 11),
            errorMessage: SQL.optionalColumn(stmt, 12)
        )
    }

    func decodeResult(from stmt: OpaquePointer?) -> ExtractionResult? {
        guard let outputKind = ExtractionOutputKind(rawValue: SQL.column(stmt, 5)),
              let sourceRecordIDs = decodeJSONString([String].self, from: SQL.column(stmt, 10)),
              let status = ExtractionResultStatus(rawValue: SQL.column(stmt, 12))
        else { return nil }

        return ExtractionResult(
            id: SQL.column(stmt, 0),
            runID: SQL.column(stmt, 1),
            recipeID: SQL.column(stmt, 2),
            createdAt: iso.date(from: SQL.column(stmt, 3)) ?? Date(),
            updatedAt: iso.date(from: SQL.column(stmt, 4)) ?? Date(),
            outputKind: outputKind,
            title: SQL.column(stmt, 6),
            content: SQL.column(stmt, 7),
            summary: SQL.optionalColumn(stmt, 8),
            payloadJSON: SQL.column(stmt, 9),
            sourceRecordIDs: sourceRecordIDs,
            sourceRecordCount: Int(sqlite3_column_int(stmt, 11)),
            status: status,
            score: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 13),
            reviewReason: SQL.optionalColumn(stmt, 14),
            isFavorite: sqlite3_column_int(stmt, 15) == 1
        )
    }

    func decodeAsset(from stmt: OpaquePointer?) -> LanguageAsset? {
        guard let assetType = LanguageAssetType(rawValue: SQL.column(stmt, 3)),
              let status = LanguageAssetStatus(rawValue: SQL.column(stmt, 17)),
              let scenes = decodeJSONString([String].self, from: SQL.column(stmt, 9)),
              let audiences = decodeJSONString([String].self, from: SQL.column(stmt, 10)),
              let keywords = decodeJSONString([String].self, from: SQL.column(stmt, 12)),
              let sourceRecordIDs = decodeJSONString([String].self, from: SQL.column(stmt, 13))
        else { return nil }

        return LanguageAsset(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            updatedAt: iso.date(from: SQL.column(stmt, 2)) ?? Date(),
            assetType: assetType,
            grade: SQL.optionalColumn(stmt, 4).flatMap { LanguageAssetGrade(rawValue: $0) },
            title: SQL.optionalColumn(stmt, 5),
            content: SQL.column(stmt, 6),
            summary: SQL.optionalColumn(stmt, 7),
            reason: SQL.optionalColumn(stmt, 8),
            scenes: scenes,
            audiences: audiences,
            ruleHit: SQL.optionalColumn(stmt, 11),
            keywords: keywords,
            sourceRecordIDs: sourceRecordIDs,
            sourceRecordCount: Int(sqlite3_column_int(stmt, 14)),
            extractionJobID: SQL.optionalColumn(stmt, 15),
            isFavorite: sqlite3_column_int(stmt, 16) == 1,
            status: status
        )
    }

    func decodeCandidate(from stmt: OpaquePointer?) -> LanguageAssetCandidateRecord? {
        guard let assetType = LanguageAssetType(rawValue: SQL.column(stmt, 3)),
              let grade = LanguageAssetGrade(rawValue: SQL.column(stmt, 4)),
              let scenes = decodeJSONString([String].self, from: SQL.column(stmt, 9)),
              let audiences = decodeJSONString([String].self, from: SQL.column(stmt, 10)),
              let sourceRecordIDs = decodeJSONString([String].self, from: SQL.column(stmt, 12)),
              let status = LanguageAssetCandidateStatus(rawValue: SQL.column(stmt, 15))
        else { return nil }

        return LanguageAssetCandidateRecord(
            id: SQL.column(stmt, 0),
            createdAt: iso.date(from: SQL.column(stmt, 1)) ?? Date(),
            updatedAt: iso.date(from: SQL.column(stmt, 2)) ?? Date(),
            assetType: assetType,
            grade: grade,
            title: SQL.column(stmt, 5),
            content: SQL.column(stmt, 6),
            summary: SQL.optionalColumn(stmt, 7),
            reason: SQL.column(stmt, 8),
            scenes: scenes,
            audiences: audiences,
            ruleHit: SQL.optionalColumn(stmt, 11),
            sourceRecordIDs: sourceRecordIDs,
            sourceRecordCount: Int(sqlite3_column_int(stmt, 13)),
            extractionJobID: SQL.optionalColumn(stmt, 14),
            status: status
        )
    }

    func encodeJSONString<T: Encodable>(_ value: T, encoder: JSONEncoder) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    func decodeJSONString<T: Decodable>(_ type: T.Type, from value: String) -> T? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
