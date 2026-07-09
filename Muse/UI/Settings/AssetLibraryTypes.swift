import SwiftUI

// 2026-07 重构批三：三区改四区——提炼(主动作) / 待确认(统一拍板) / 资产库 / 配方(唯一定义入口)
enum PurifierView: String, CaseIterable, Identifiable {
    case extract
    case pending
    case library
    case recipes

    var id: String { rawValue }

    static let visibleCases: [PurifierView] = [
        .extract,
        .pending,
        .library,
        .recipes,
    ]

    var title: String {
        switch self {
        case .extract:
            return L("提炼", "Extract")
        case .pending:
            return L("待确认", "To review")
        case .library:
            return L("资产库", "Library")
        case .recipes:
            return L("配方", "Recipes")
        }
    }
}

/// 提炼范围选项（2026-06-12 用户调整：按天数三档 + 手动；
/// 「最近 N 条」语义挪进手动选择弹窗的快捷勾选）
enum AssetExtractionRangeOption: String, CaseIterable, Identifiable, Hashable {
    case last1Day
    case last7Days
    case last30Days
    case manual

    var id: String { rawValue }

    static let simpleCases: [AssetExtractionRangeOption] = [
        .last1Day,
        .last7Days,
        .last30Days,
    ]

    var title: String {
        switch self {
        case .last1Day:
            return L("最近 1 天", "Last day")
        case .last7Days:
            return L("最近 7 天", "Last 7 days")
        case .last30Days:
            return L("最近 30 天", "Last 30 days")
        case .manual:
            return L("手动选择", "Manual")
        }
    }

    func makeConfiguration() -> AssetExtractionConfiguration? {
        switch self {
        case .last1Day:
            return .last1Day(maxRecordCount: 50)
        case .last7Days:
            return .last7Days(maxRecordCount: 50)
        case .last30Days:
            return .last30Days(maxRecordCount: 100)
        case .manual:
            return nil
        }
    }

    private static let defaultsKey = "tf_assetExtractionRange"

    static func loadSaved() -> Self {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let option = Self(rawValue: raw)
        else { return .last7Days }
        return option == .manual ? .last7Days : option
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// 待审池的状态筛选（2026-06-11 改造方案 #5：忽略可反悔）
enum AssetCandidateStatusFilter: String, CaseIterable, Identifiable {
    case pending
    case ignored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending:
            return L("待审", "Pending")
        case .ignored:
            return L("已忽略", "Ignored")
        }
    }
}

extension AssetExtractionProgressStage {
    var title: String {
        switch self {
        case .preparing:
            return L("准备提炼", "Preparing")
        case .loadingRecords:
            return L("读取识别记录", "Loading records")
        case .filteringInputs:
            return L("筛选低价值输入", "Filtering")
        case .callingModel:
            return L("调用模型提炼", "Extracting")
        case .normalizingResults:
            return L("整理提炼产物", "Normalizing")
        case .reviewingResults:
            return L("按标准严审产物", "Reviewing")
        case .savingCandidates:
            return L("写入候选资产", "Saving candidates")
        }
    }

    var detail: String {
        switch self {
        case .preparing:
            return L("正在确认提炼范围和规则", "Checking range and rules")
        case .loadingRecords:
            return L("正在读取最近的语音输入记录", "Reading recent transcription records")
        case .filteringInputs:
            return L("正在过滤寒暄、噪声和重复内容", "Filtering low-value and duplicate inputs")
        case .callingModel:
            return L("正在构造 Prompt 并调用模型提炼", "Building the prompt and calling the model")
        case .normalizingResults:
            return L("正在解析提炼产物，去重并校验来源", "Parsing, deduplicating, and validating sources")
        case .reviewingResults:
            return L("正在按配方的入库/忽略标准逐条判决", "Judging each result against recipe standards")
        case .savingCandidates:
            return L("正在写入今日发现，稍后即可判断入库", "Saving candidates to Today")
        }
    }

    var displayIndex: Int {
        rawValue + 1
    }
}

struct AssetExtractionPreviewContext: Hashable {
    let recipeIDs: [String]
    let recipeNames: [String]
    let range: AssetExtractionRangeOption
    let includesProcessedRecords: Bool
    let selectedRecordIDs: [String]

    init(
        recipeIDs: [String] = [ExtractionRecipe.quoteAssetsID],
        recipeNames: [String] = ["金句"],
        range: AssetExtractionRangeOption,
        includesProcessedRecords: Bool = false,
        selectedRecordIDs: [String] = []
    ) {
        self.recipeIDs = recipeIDs.isEmpty ? [ExtractionRecipe.quoteAssetsID] : recipeIDs
        self.recipeNames = recipeNames.isEmpty ? ["金句"] : recipeNames
        self.range = range
        self.includesProcessedRecords = includesProcessedRecords
        self.selectedRecordIDs = selectedRecordIDs
    }

    var primaryRecipeID: String {
        recipeIDs.first ?? ExtractionRecipe.quoteAssetsID
    }

    var id: String {
        let recipeKey = recipeIDs.joined(separator: "-")
        switch range {
        case .manual:
            return "\(recipeKey)-manual-\(selectedRecordIDs.count)-\(selectedRecordIDs.hashValue)"
        default:
            return "\(recipeKey)-\(range.rawValue)-\(includesProcessedRecords)"
        }
    }

    var recipeName: String {
        if recipeNames.count <= 2 {
            return recipeNames.joined(separator: "、")
        }
        let head = recipeNames.prefix(2).joined(separator: "、")
        return "\(head) 等 \(recipeNames.count) 个"
    }

    func makeConfigurations() -> [AssetExtractionConfiguration] {
        if range == .manual {
            let base = AssetExtractionConfiguration
                .manualSelection(ids: selectedRecordIDs)
            return recipeIDs.map { base.applying(recipeID: $0) }
        }
        guard let base = range.makeConfiguration()?
            .includingProcessedRecords(includesProcessedRecords)
        else { return [] }
        return recipeIDs.map { base.applying(recipeID: $0) }
    }
}

enum AssetLibrarySheet: Identifiable {
    case candidateSources(LanguageAssetCandidateRecord)
    case resultSources(ExtractionResult)
    case candidateEditor(LanguageAssetCandidateRecord)
    case recipeEditor(ExtractionRecipe?)
    case extractionRangeSelection
    case extractionPreview(AssetExtractionPreview, AssetExtractionPreviewContext)
    case manualRecordSelection([HistoryRecord])

    var id: String {
        switch self {
        case .candidateSources(let candidate):
            return "candidate-sources-\(candidate.id)"
        case .resultSources(let result):
            return "result-sources-\(result.id)"
        case .candidateEditor(let candidate):
            return "candidate-editor-\(candidate.id)"
        case .recipeEditor(let recipe):
            return "recipe-editor-\(recipe?.id ?? "new")"
        case .extractionRangeSelection:
            return "extraction-range-selection"
        case .extractionPreview(_, let context):
            return "extraction-preview-\(context.id)"
        case .manualRecordSelection:
            return "manual-record-selection"
        }
    }
}

enum AssetLibraryStyle {
    static let sectionSpacing: CGFloat = TF.settingsCardSpacing
    /// 顶栏去壳后 = 控件高（2026-07-08 大梁老师：与常用词页顶部开关同款裸排）
    static let toolbarHeight: CGFloat = SettingsControlSpec.actionHeight
    static let discoverPanelPadding: CGFloat = TF.settingsInnerCardPadding
    static let navigationWidth: CGFloat = 170
    static let navigationHorizontalPadding: CGFloat = 11
    static let navigationTopPadding: CGFloat = 12
    static let navigationSearchListSpacing: CGFloat = 8
    static let navigationGroupSpacing: CGFloat = 6
    static let navigationItemSpacing: CGFloat = 3
    static let compactItemMinHeight: CGFloat = 32
    static let detailTopPadding: CGFloat = 15
    static let detailLeadingPadding: CGFloat = 12
    static let detailHeaderHeight: CGFloat = 20
    static let detailTitleHeight: CGFloat = 36
    static let detailSectionSpacing: CGFloat = 10
    static let detailFooterTopPadding: CGFloat = 9
    static let detailFooterMinHeight: CGFloat = 38
    static let panelCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let innerPanelCornerRadius: CGFloat = TF.settingsInnerCardCornerRadius
    static let controlCornerRadius: CGFloat = TF.settingsControlCornerRadius
    // 2026-06-12 用户指出本页卡底（原 settingsBg）比其他页（settingsCardAlt）暗一档：
    // 卡底与全局统一；导航列改用次级填充，保持比卡底亮一层的分栏关系
    static let shellFill = TF.settingsCardAlt
    static let restingWhite = TF.settingsSecondaryActionFill
    static let primaryInk = TF.settingsPrimaryActionText
}
