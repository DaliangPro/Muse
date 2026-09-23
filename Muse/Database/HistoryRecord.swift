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

    /// 识别记录只展示一个模式标签。直出模式兼容历史上曾写入的“正常输出”名称；
    /// 其他模式沿用写入时的名称，旧记录没有模式时不猜测。
    var processingModeDisplayName: String? {
        guard let processingMode,
              !processingMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let directAliases = Set([
            ProcessingMode.direct.name,
            "正常输出", "Normal Output", "直出", "Direct", "Direct Output", "直出模式"
        ])
        if directAliases.contains(processingMode) {
            if status.hasPrefix("voice_polish_") {
                return L("轻度润色", "Light Polish")
            }
            return L("直出", "Direct")
        }
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
