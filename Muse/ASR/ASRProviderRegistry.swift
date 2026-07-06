import Foundation

enum ASRAudioInputKind: Sendable, Equatable {
    case pcmData
    case pcmBuffer
}

struct ASRProviderCapabilities: Sendable, Equatable {
    let isAvailable: Bool
    /// False for batch/REST providers that only produce results in endAudio().
    let isStreaming: Bool
    let audioInput: ASRAudioInputKind

    static func streaming(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: true, audioInput: audioInput)
    }

    static func batch(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: false, audioInput: audioInput)
    }

    static let unavailable = ASRProviderCapabilities(
        isAvailable: false,
        isStreaming: true,
        audioInput: .pcmData
    )
}

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities

        var isAvailable: Bool { createClient != nil }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            capabilities: ASRProviderCapabilities = .unavailable
        ) {
            self.configType = configType
            self.createClient = createClient
            self.capabilities = capabilities
        }
    }

    static let all: [ASRProvider: ProviderEntry] = {
        var dict: [ASRProvider: ProviderEntry] = [
            .apple: ProviderEntry(
                configType: AppleASRConfig.self,
                createClient: { AppleASRClient() },
                capabilities: .streaming(audioInput: .pcmBuffer)
            ),
            .volcano: ProviderEntry(
                configType: VolcanoASRConfig.self,
                createClient: { VolcASRClient() },
                capabilities: .streaming()
            ),
        ]
        #if HAS_SHERPA_ONNX
        dict[.sherpa] = ProviderEntry(
            configType: SherpaASRConfig.self,
            createClient: { SenseVoiceWSClient() },
            capabilities: .batch()  // full_inference at end takes 3-5s, needs longer timeout
        )
        #else
        dict[.sherpa] = ProviderEntry(configType: SherpaASRConfig.self, createClient: nil)
        #endif
        return dict
    }()

    static func entry(for provider: ASRProvider) -> ProviderEntry? {
        all[provider]
    }

    static func configType(for provider: ASRProvider) -> (any ASRProviderConfig.Type)? {
        all[provider]?.configType
    }

    static func createClient(for provider: ASRProvider) -> (any SpeechRecognizer)? {
        all[provider]?.createClient?()
    }

    static func capabilities(for provider: ASRProvider) -> ASRProviderCapabilities {
        all[provider]?.capabilities ?? .unavailable
    }

    static func supports(_ mode: ProcessingMode, for provider: ASRProvider) -> Bool {
        if mode.id == ProcessingMode.directId {
            return capabilities(for: provider).isAvailable
        }
        return true
    }

    static func supportedModes(from modes: [ProcessingMode], for provider: ASRProvider) -> [ProcessingMode] {
        modes.filter { supports($0, for: provider) }
    }

    static func resolvedMode(for mode: ProcessingMode, provider: ASRProvider) -> ProcessingMode {
        supports(mode, for: provider) ? mode : .direct
    }

}
