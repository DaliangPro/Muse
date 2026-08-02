// 顺序即侧栏顺序：Voice Polish 的术语与成稿设置都拥有稳定的一级入口，
// 不再依赖用户先进入输入模式并选中某个模式。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case assetLibrary
    case vocabulary
    case voicePolish
    case modes
    case models
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:     return L("概览与记录", "Overview")
        case .assetLibrary:return L("语料资产", "Asset Library")
        case .modes:       return L("输入模式", "Input Modes")
        case .vocabulary:  return L("术语与纠错", "Terminology")
        case .voicePolish: return L("语音润色", "Voice Polish")
        case .models:      return L("模型配置", "Model Config")
        case .about:       return L("关于", "About")
        }
    }

}
