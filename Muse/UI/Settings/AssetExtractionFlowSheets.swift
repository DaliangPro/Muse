import AppKit
import SwiftUI

// 2026-07 重设计：提炼弹窗 = 勾选配方(可多选) + 选范围。
// 不再金句专属；Prompt 属于配方(配方页编辑)，提炼时不再改。
// 2026-07-08 大梁老师：点开始后弹窗不关闭，原地切换为「提炼中」形态（窗体收拢 +
// 旋转光环 + 阶段进度），页面不再显示进度横幅；完成后由外层关弹窗并跳待确认。
struct AssetExtractionRangeSelectionSheet: View {
    let recipes: [ExtractionRecipe]
    let isExtracting: Bool
    let progressPhase: AssetExtractionProgressStage
    /// 范围内无可提炼内容时的就地提示（不弹错、不关窗，让用户直接换范围）
    let emptyNotice: String?
    let onConfirm: (Set<String>, AssetExtractionRangeOption) -> Void
    let onCancelExtraction: () -> Void
    let onCancel: () -> Void

    @State private var selectedRange: AssetExtractionRangeOption
    @State private var selectedRecipeIDs: Set<String>

    init(
        recipes: [ExtractionRecipe],
        selectedRecipeIDs: Set<String>,
        selectedRange: AssetExtractionRangeOption,
        isExtracting: Bool,
        progressPhase: AssetExtractionProgressStage,
        emptyNotice: String?,
        onConfirm: @escaping (Set<String>, AssetExtractionRangeOption) -> Void,
        onCancelExtraction: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.recipes = recipes
        self.isExtracting = isExtracting
        self.progressPhase = progressPhase
        self.emptyNotice = emptyNotice
        self.onConfirm = onConfirm
        self.onCancelExtraction = onCancelExtraction
        self.onCancel = onCancel
        let validIDs = Set(recipes.map(\.id))
        let initial = selectedRecipeIDs.intersection(validIDs)
        _selectedRecipeIDs = State(initialValue: initial.isEmpty ? Set([recipes.first?.id].compactMap { $0 }) : initial)
        _selectedRange = State(initialValue: selectedRange == .manual ? .last7Days : selectedRange)
    }

    var body: some View {
        ZStack {
            if isExtracting {
                extractingContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                selectionContent
                    .transition(.opacity)
            }
        }
        .frame(
            width: isExtracting ? 380 : 488,
            height: isExtracting ? 316 : 560
        )
        .background(TF.settingsCanvas)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isExtracting)
        .interactiveDismissDisabled(isExtracting)
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            content

            Spacer(minLength: 0)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 提炼中形态：旋转光环 + 阶段文字 + 分段进度点，安静优雅不打扰

    private var extractingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 旋转用 TimelineView 按时间算角度，不走 repeatForever 动画事务——
            // 后者会把弹窗收拢的布局位移一并捕获进无限重放（2026-07-08 修：内容反复从右下漂移）
            TimelineView(.animation) { context in
                let period: Double = 1.05
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                ZStack {
                    Circle()
                        .stroke(TF.settingsStroke.opacity(0.45), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: 0.32)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    TF.settingsAccentGreen.opacity(0),
                                    TF.settingsAccentGreen,
                                ]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(progress * 360))
                }
            }
            .frame(width: 54, height: 54)
            .padding(.bottom, 18)

            Text(progressPhase.title)
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsText)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: progressPhase)
                .padding(.bottom, 5)

            Text(L("\(selectedRecipeIDs.count) 个配方 · \(selectedRange.title)", "\(selectedRecipeIDs.count) recipes · \(selectedRange.title)"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 18)

            stageDots

            Spacer(minLength: 0)

            SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancelExtraction)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }

    /// 七段管线进度点：走到的点亮绿、当前段拉长为胶囊，一眼看出进行到哪
    private var stageDots: some View {
        HStack(spacing: 7) {
            ForEach(AssetExtractionProgressStage.allCases, id: \.rawValue) { stage in
                Capsule()
                    .fill(
                        stage.rawValue <= progressPhase.rawValue
                            ? TF.settingsAccentGreen
                            : TF.settingsStroke.opacity(0.55)
                    )
                    .frame(width: stage == progressPhase ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progressPhase)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("提炼语料资产", "Extract language assets"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)

                Text(L("选配方和范围。产物先宽提找全、再按配方 Prompt 严审，最后进待确认。", "Pick recipes and a range. Results are widened, reviewed, then wait for you."))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("提炼目标（可多选）", "Recipes (multi-select)"))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.leading, 2)

                // 一行两个，紧凑不散（2026-07 大梁老师：一卡一行太乱）
                ScrollView(showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(recipes) { recipe in
                            recipeRow(recipe)
                        }
                    }
                }
                .settingsThinScrollIndicators()
                .frame(maxHeight: 128)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("提炼范围", "Range"))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.leading, 2)

                VStack(spacing: 6) {
                    ForEach(AssetExtractionRangeOption.simpleCases) { range in
                        rangeRow(range)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let emptyNotice {
                Text(emptyNotice)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsAccentAmber)
                    .lineLimit(2)
            }
            Spacer()
            SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
            SettingsTextButton(L("开始提炼", "Start extraction"), variant: .primary, minWidth: 82) {
                onConfirm(selectedRecipeIDs, selectedRange)
            }
            .disabled(selectedRecipeIDs.isEmpty)
            .opacity(selectedRecipeIDs.isEmpty ? 0.55 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(TF.settingsCanvas)
    }

    private func recipeRow(_ recipe: ExtractionRecipe) -> some View {
        let isSelected = selectedRecipeIDs.contains(recipe.id)

        return SettingsPlainButton {
            if isSelected {
                selectedRecipeIDs.remove(recipe.id)
            } else {
                selectedRecipeIDs.insert(recipe.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(TF.settingsFontIconControl)
                    .foregroundStyle(isSelected ? TF.settingsAccentGreen : TF.settingsTextTertiary)

                Circle()
                    .fill(recipe.outputKind.settingsAccentColor)
                    .frame(width: 5, height: 5)

                Text(recipe.name)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                    .fill(TF.settingsCardAlt)
            )
            .contentShape(RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous))
        }
    }

    private func rangeRow(_ range: AssetExtractionRangeOption) -> some View {
        let isSelected = selectedRange == range

        return SettingsPlainButton {
            selectedRange = range
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(TF.settingsFontIconControl)
                    .foregroundStyle(isSelected ? TF.settingsAccentGreen : TF.settingsTextTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(range.title)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)

                    Text(rangeSubtitle(range))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                    .fill(TF.settingsCardAlt)
            )
            .contentShape(RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous))
        }
    }

    private func rangeSubtitle(_ range: AssetExtractionRangeOption) -> String {
        switch range {
        case .last1Day:
            return L("适合刚录完一批内容后的快速提炼", "Best for a quick pass after recent input")
        case .last7Days:
            return L("默认范围，兼顾新内容和上下文密度", "Default range with balanced context")
        case .last30Days:
            return L("适合较长时间未提炼后的补提", "Use when you have not extracted in a while")
        case .manual:
            return ""
        }
    }
}

private extension ExtractionRecipe {
    var assetDefinitionGroupName: String {
        let templateGroups = AssetDefinitionTemplateGroup.defaults()
        for group in templateGroups where group.templates.contains(where: { $0.name == name }) {
            return group.name
        }
        switch id {
        case ExtractionRecipe.quoteAssetsID:
            return "创作灵感类"
        case ExtractionRecipe.contentCreatorAssetsID:
            return "创作灵感类"
        case ExtractionRecipe.todayTodosID, ExtractionRecipe.dailyReportID:
            return "工作效率类"
        default:
            return "自定义"
        }
    }

    var shortTitle: String {
        switch id {
        case ExtractionRecipe.quoteAssetsID:
            return L("金句", "Quotes")
        case ExtractionRecipe.contentCreatorAssetsID:
            return L("内容素材", "Assets")
        case ExtractionRecipe.todayTodosID:
            return L("待办", "Todos")
        case ExtractionRecipe.dailyReportID:
            return L("工作日报", "Report")
        default:
            return name
        }
    }
}

/// 提炼前确认弹窗（2026-06-11 改造方案 #7/#9）：
/// 本地零成本算好范围与过滤结果，截断/防重排除全部明示，确认后才花模型钱
struct ExtractionPreviewSheet: View {
    let preview: AssetExtractionPreview
    let context: AssetExtractionPreviewContext
    let ruleConfig: AssetExtractionRuleConfig
    let provider: LLMProvider
    let promptMessages: AssetExtractionPromptMessages
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isPromptPreviewPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(L("确认提炼", "Confirm extraction"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)

                Spacer(minLength: 0)

                SettingsTextButton(
                    L("最终 Prompt", "Final Prompt"),
                    variant: .secondary,
                    controlSize: .compact,
                    onCanvas: true
                ) {
                    isPromptPreviewPresented = true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                previewRow(L("提炼目标", "Target"), context.recipeName)
                previewRow(L("范围", "Range"), context.range.title)
                previewRow(
                    L("将提炼", "Will extract"),
                    L("\(preview.eligibleCount) 条记录 · 约 \(preview.totalCharacters) 字", "\(preview.eligibleCount) records · ~\(preview.totalCharacters) chars")
                )
                if context.includesProcessedRecords {
                    previewRow(
                        L("已处理", "Processed"),
                        L("包含在本次提炼", "Included this run")
                    )
                } else if preview.excludedAsProcessedCount > 0 {
                    previewRow(
                        L("已提炼过", "Already processed"),
                        L("跳过 \(preview.excludedAsProcessedCount) 条", "\(preview.excludedAsProcessedCount) skipped")
                    )
                }
                if preview.truncatedCount > 0 {
                    previewRow(
                        L("超出上限", "Over limit"),
                        L("\(preview.truncatedCount) 条不参与本次提炼", "\(preview.truncatedCount) dropped this run"),
                        isWarning: true
                    )
                }
                previewRow(
                    L("规则", "Rules"),
                    "\(ruleConfig.saveThreshold.title) · \(ruleConfig.lowValueFilter.title) · \(ruleConfig.audienceFocus)"
                )
                previewRow(
                    L("模型", "Model"),
                    provider.displayName
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius)
                    .fill(TF.settingsCardAlt)
            )

            if preview.eligibleCount == 0 {
                Text(L("范围内没有可提炼的新内容，换个范围试试。", "Nothing new to extract in this range."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
            } else if !context.includesProcessedRecords && preview.excludedAsProcessedCount > 0 {
                Text(L("已提炼过的记录会自动跳过。需要复测旧语料时，先清空提炼结果再提炼。", "Already processed records are skipped. Clear extraction results before retesting old records."))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsAccentAmber)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
                SettingsTextButton(L("开始提炼", "Start"), variant: .primary, action: onConfirm)
                    .disabled(preview.eligibleCount == 0)
                    .opacity(preview.eligibleCount == 0 ? 0.6 : 1)
            }
        }
        .padding(18)
        .frame(width: 408, height: 348, alignment: .topLeading)
        .background(TF.settingsCanvas)
        .sheet(isPresented: $isPromptPreviewPresented) {
            AssetExtractionPromptPreviewSheet(
                provider: provider,
                messages: promptMessages,
                onClose: { isPromptPreviewPresented = false }
            )
        }
    }

    private func previewRow(_ label: String, _ value: String, isWarning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(TF.settingsFontBody)
                .foregroundStyle(isWarning ? TF.settingsAccentAmber : TF.settingsText)
            Spacer(minLength: 0)
        }
    }
}

struct AssetExtractionPromptPreviewSheet: View {
    let provider: LLMProvider
    let messages: AssetExtractionPromptMessages
    let onClose: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("最终 Prompt", "Final Prompt"))
                        .font(TF.settingsFontSectionTitle)
                        .foregroundStyle(TF.settingsText)
                    Text(L("\(provider.displayName) · system / user 两段真实请求", "\(provider.displayName) · actual system / user messages"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Spacer(minLength: 0)

                SettingsTextButton(
                    didCopy ? L("已复制", "Copied") : L("复制", "Copy"),
                    variant: .secondary,
                    controlSize: .compact,
                    onCanvas: true
                ) {
                    copyPrompt()
                }
                SettingsTextButton(
                    L("关闭", "Close"),
                    variant: .primary,
                    controlSize: .compact,
                    action: onClose
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    promptSection(
                        title: "SYSTEM",
                        content: messages.system ?? L("无 system message", "No system message")
                    )
                    promptSection(title: "USER", content: messages.user)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .settingsThinScrollIndicators()
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                    .fill(TF.settingsCardAlt)
            )
        }
        .padding(18)
        .frame(width: 720, height: 560, alignment: .topLeading)
        .background(TF.settingsCanvas)
    }

    private func promptSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)

            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TF.settingsText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messages.combinedForDisplay, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

/// 手动选择记录弹窗（2026-06-11 改造方案 #3：manualSelection 范围接线）
struct ManualRecordSelectionSheet: View {
    let records: [HistoryRecord]
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<String> = []

    /// 快捷档位只展示数据量够得着的（不足 10 条就没必要显示「近 10 条」）
    private var quickPickCounts: [Int] {
        [10, 50, 100].filter { $0 <= records.count }
    }

    private func isQuickPickActive(_ count: Int) -> Bool {
        selectedIDs == Set(records.prefix(count).map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(L("选择要提炼的记录", "Pick records to extract"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)

                Spacer(minLength: 8)

                // 快捷勾选最近 N 条（2026-06-12 用户拍板），勾完仍可逐条微调
                ForEach(quickPickCounts, id: \.self) { count in
                    SettingsTextButton(
                        L("近 \(count) 条", "Top \(count)"),
                        variant: isQuickPickActive(count) ? .selected : .secondary,
                        controlSize: .compact,
                        onCanvas: true
                    ) {
                        selectedIDs = Set(records.prefix(count).map(\.id))
                    }
                }
            }

            if records.isEmpty {
                Text(L("没有可选择的识别记录。", "No records available."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(records, id: \.id) { record in
                            recordRow(record)
                        }
                    }
                }
                .settingsThinScrollIndicators()
            }

            HStack {
                Text(L("已选 \(selectedIDs.count) 条", "\(selectedIDs.count) selected"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
                SettingsTextButton(L("提炼所选", "Extract"), variant: .primary) {
                    onConfirm(Array(selectedIDs))
                }
                .disabled(selectedIDs.isEmpty)
                .opacity(selectedIDs.isEmpty ? 0.6 : 1)
            }
        }
        .padding(18)
        .frame(width: 460, height: 420, alignment: .topLeading)
        .background(TF.settingsCanvas)
    }

    private func recordRow(_ record: HistoryRecord) -> some View {
        let isSelected = selectedIDs.contains(record.id)

        return SettingsPlainButton {
            if isSelected {
                selectedIDs.remove(record.id)
            } else {
                selectedIDs.insert(record.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(TF.settingsFontIconControl)
                    .foregroundStyle(isSelected ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.formatDate(record.createdAt))
                        .font(TF.settingsFontMono)
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(record.finalText)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius)
                    .fill(isSelected ? TF.settingsSelectionFill : TF.settingsCardAlt)
            )
            .contentShape(RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius))
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
