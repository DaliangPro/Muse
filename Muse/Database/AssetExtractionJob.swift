import Foundation

enum AssetExtractionRangeType: String, Codable, Sendable {
    case last1Day
    case last7Days
    case last30Days
    case lastNRecords
    case manualSelection
}

enum AssetExtractionJobStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
}

struct AssetExtractionJob: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let rangeType: AssetExtractionRangeType
    let rangePayload: String?
    let sourceRecordCount: Int
    let status: AssetExtractionJobStatus
    let summary: String?
    let errorMessage: String?
}
