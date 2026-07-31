import Foundation

enum VoicePolishSettings {
    static let defaultCorrectionLimit = 200
    static let maximumCorrectionLimit = 200

    static func qualityMode(defaults: UserDefaults = .standard) -> VoicePolishQualityMode {
        guard let raw = defaults.string(forKey: DefaultsKeys.voicePolishQualityMode),
              let value = VoicePolishQualityMode(rawValue: raw) else { return .balanced }
        return value
    }

    static func setQualityMode(
        _ value: VoicePolishQualityMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value.rawValue, forKey: DefaultsKeys.voicePolishQualityMode)
    }

    static func contextLevel(defaults: UserDefaults = .standard) -> WritingContextLevel {
        guard let raw = defaults.string(forKey: DefaultsKeys.voicePolishContextLevel),
              let value = WritingContextLevel(rawValue: raw) else { return .metadataOnly }
        return value
    }

    static func setContextLevel(
        _ value: WritingContextLevel,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value.rawValue, forKey: DefaultsKeys.voicePolishContextLevel)
    }

    static func personalizationEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKeys.voicePolishPersonalizationEnabled) as? Bool ?? false
    }

    static func setPersonalizationEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: DefaultsKeys.voicePolishPersonalizationEnabled)
    }

    static func correctionLimit(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: DefaultsKeys.voicePolishCorrectionLimit) != nil else {
            return defaultCorrectionLimit
        }
        return min(max(1, defaults.integer(forKey: DefaultsKeys.voicePolishCorrectionLimit)), maximumCorrectionLimit)
    }

    static func setCorrectionLimit(_ value: Int, defaults: UserDefaults = .standard) {
        defaults.set(min(max(1, value), maximumCorrectionLimit), forKey: DefaultsKeys.voicePolishCorrectionLimit)
    }

    static func sceneOverrides(defaults: UserDefaults = .standard) -> [String: WritingScene] {
        guard let data = defaults.data(forKey: DefaultsKeys.voicePolishSceneOverrides),
              let raw = try? JSONDecoder().decode([String: WritingScene].self, from: data)
        else { return [:] }
        return raw
    }

    static func setSceneOverrides(
        _ overrides: [String: WritingScene],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: DefaultsKeys.voicePolishSceneOverrides)
    }
}
