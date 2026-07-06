import SwiftUI

enum ModelSettingsStyle {
    static let outerCardCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let inspectorLabelWidth: CGFloat = 84
    static let inspectorControlWidth: CGFloat = 240
    static let inspectorRowHeight: CGFloat = 34
    static let inspectorFieldHeight: CGFloat = 28
    static let inspectorRowSpacing: CGFloat = 4
    static let cardSpacing: CGFloat = TF.settingsCardSpacing
    static let headerBottomSpacing: CGFloat = 10
    static let footerTopSpacing: CGFloat = 12
    static let cardFillColor: Color = TF.settingsCardAlt
    static let summaryCardMinHeight: CGFloat = 92
    static let summaryCardMinWidth: CGFloat = 188
    static let resourceStripMinHeight: CGFloat = 72
    static let localInventoryRowHeight: CGFloat = 44
}

@MainActor
enum ModelConnectivityCache {
    static var asr: (provider: ASRProvider, status: SettingsTestStatus)?
    static var llm: (provider: LLMProvider, status: SettingsTestStatus)?
    static var asset: (provider: LLMProvider, status: SettingsTestStatus)?
}
