import Foundation

struct RecognitionSegment: Sendable, Equatable, Codable {
    let id: String
    let text: String
    let startTimeMs: Int?
    let endTimeMs: Int?
    let confidence: Double?
    let isFinal: Bool
}

struct VoiceInputEnvelope: Sendable, Equatable {
    /// ASR Provider 最终实际可用的原样终稿。
    let providerFinalText: String
    /// 只有确实存在独立标点恢复结果时才设置。
    let punctuatedText: String?
    let segments: [RecognitionSegment]
    let durationMs: Int
    let detectedLanguage: String?
    let provider: ASRProvider

    var fallbackText: String {
        VoicePolishCharacterSafety.sanitizedFallback(
            punctuatedText ?? providerFinalText
        )
    }

    init(
        providerFinalText: String,
        punctuatedText: String? = nil,
        segments: [RecognitionSegment],
        durationMs: Int,
        detectedLanguage: String? = nil,
        provider: ASRProvider
    ) {
        self.providerFinalText = providerFinalText
        self.punctuatedText = punctuatedText
        self.segments = segments
        self.durationMs = max(0, durationMs)
        self.detectedLanguage = detectedLanguage
        self.provider = provider
    }

    static func fromFinalTranscript(
        _ transcript: RecognitionTranscript,
        finalText: String,
        durationMs: Int,
        provider: ASRProvider
    ) -> VoiceInputEnvelope? {
        let trimmedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFinal.isEmpty else { return nil }

        let sourceSegments = transcript.confirmedSegments
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let segments: [RecognitionSegment]
        let confirmedText = sourceSegments.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceSegments.isEmpty || confirmedText != trimmedFinal {
            segments = [RecognitionSegment(
                id: "s1",
                text: trimmedFinal,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )]
        } else {
            segments = sourceSegments.enumerated().map { index, text in
                RecognitionSegment(
                    id: "s\(index + 1)",
                    text: text,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
            }
        }

        return VoiceInputEnvelope(
            providerFinalText: trimmedFinal,
            punctuatedText: nil,
            segments: segments,
            durationMs: durationMs,
            provider: provider
        )
    }
}
