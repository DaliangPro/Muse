import SwiftUI

extension LanguageAssetType {
    var settingsDisplayTitle: String {
        switch self {
        case .question:
            return L("好问题", "Questions")
        case .viewpoint:
            return L("好观点", "Viewpoints")
        case .framework:
            return L("表达框架", "Frameworks")
        case .caseMaterial:
            return L("案例素材", "Case Materials")
        case .quote:
            return L("金句短句", "Quotes")
        case .term:
            return L("高频术语", "Terms")
        case .snippet:
            return L("可复用片段", "Snippets")
        }
    }

    var settingsAccentColor: Color {
        switch self {
        case .question:
            return TF.settingsAccentAmber
        case .viewpoint:
            return TF.settingsAccentGreen
        case .framework:
            return TF.settingsAccentBlue
        case .caseMaterial:
            return Color(red: 120 / 255, green: 132 / 255, blue: 154 / 255)
        case .quote:
            return TF.settingsAccentRed
        case .term:
            return TF.settingsAccentGreen
        case .snippet:
            return TF.settingsAccentBlue
        }
    }
}
