import Foundation

enum LanguageAssetType: String, Codable, CaseIterable, Sendable {
    case question
    case viewpoint
    case framework
    case caseMaterial = "case_material"
    case quote
    // Legacy asset types kept readable for existing local databases.
    case term
    case snippet

    static let creatorCases: [LanguageAssetType] = [
        .question,
        .viewpoint,
        .framework,
        .caseMaterial,
        .quote,
    ]
}

enum LanguageAssetGrade: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
}

enum LanguageAssetCandidateStatus: String, Codable, Sendable {
    case pending
    case saved
    case ignored
}

enum LanguageAssetStatus: String, Codable, Sendable {
    case active
    case archived
    case deleted
}

enum LanguageAssetActionType: String, Codable, Sendable {
    case extractionStarted
    case extractionSucceeded
    case extractionFailed
    case candidateSaved
    case candidateIgnored
    case candidateRestored
    case copied
    case favorited
    case unfavorited
    case deleted
}

struct LanguageAsset: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let assetType: LanguageAssetType
    let grade: LanguageAssetGrade?
    let title: String?
    let content: String
    let summary: String?
    let reason: String?
    let scenes: [String]
    let audiences: [String]
    let ruleHit: String?
    let keywords: [String]
    let sourceRecordIDs: [String]
    let sourceRecordCount: Int
    let extractionJobID: String?
    let isFavorite: Bool
    let status: LanguageAssetStatus
}

struct LanguageAssetCandidateRecord: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let assetType: LanguageAssetType
    let grade: LanguageAssetGrade
    let title: String
    let content: String
    let summary: String?
    let reason: String
    let scenes: [String]
    let audiences: [String]
    let ruleHit: String?
    let sourceRecordIDs: [String]
    let sourceRecordCount: Int
    let extractionJobID: String?
    let status: LanguageAssetCandidateStatus
}

struct LanguageAssetActionLog: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let createdAt: Date
    let assetID: String?
    let actionType: LanguageAssetActionType
    let detail: String?
}
