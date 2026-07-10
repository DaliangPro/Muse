enum ASRRequestOptionsFactory {
    static func current(enablePunc: Bool) -> ASRRequestOptions {
        let biasSettings = ASRBiasSettingsStorage.load()
        let userWords = HotwordStorage.load()
        return ASRRequestOptions(
            enablePunc: enablePunc,
            hotwords: userWords,
            userHotwordCount: userWords.count,
            correctionWords: SnippetStorage.userCorrectionWords(),
            boostingTableID: biasSettings.boostingTableID,
            contextHistoryLength: biasSettings.contextHistoryLength
        )
    }
}
