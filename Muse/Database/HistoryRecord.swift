import Foundation

struct HistoryRecord: Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: Date
    let durationSeconds: Double
    let rawText: String
    let processingMode: String?
    let processedText: String?
    let finalText: String
    let status: String
    let characterCount: Int?
    let tokenCount: Int?

    /// 只展示写入时的模式名；旧记录没有模式时不推断轻度、标准或直出。
    var processingModeDisplayName: String? {
        guard let processingMode,
              !processingMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return processingMode
    }

    init(
        id: String,
        createdAt: Date,
        durationSeconds: Double,
        rawText: String,
        processingMode: String?,
        processedText: String?,
        finalText: String,
        status: String,
        characterCount: Int?,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.processingMode = processingMode
        self.processedText = processedText
        self.finalText = finalText
        self.status = status
        self.characterCount = characterCount
        self.tokenCount = tokenCount
    }
}
