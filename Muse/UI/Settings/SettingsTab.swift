// 顺序即侧栏顺序（2026-06-12 用户拍板）：概览→语料资产→常用词→输入模式→模型配置→关于
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case assetLibrary
    case vocabulary
    case modes
    case models
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:     return L("概览与记录", "Overview")
        case .assetLibrary:return L("语料资产", "Asset Library")
        case .modes:       return L("输入模式", "Input Modes")
        case .vocabulary:  return L("常用词", "Vocabulary")
        case .models:      return L("模型配置", "Model Config")
        case .about:       return L("关于", "About")
        }
    }

}
