import AppKit
import SwiftUI

private enum VocabularyPanel: String, CaseIterable {
    case hotwords
    case snippets

    var title: String {
        switch self {
        case .hotwords:
            return L("识别热词", "Recognition Terms")
        case .snippets:
            return L("替换规则", "Replacement Rules")
        }
    }
}

struct VocabularyTab: View, SettingsCardHelpers {
    @State private var hotwords: [String] = HotwordStorage.load()
    @State private var newHotword = ""
    @State private var builtinHotwordCount = HotwordStorage.builtinCount()

    @State private var snippets: [(trigger: String, value: String)] = SnippetStorage.load()
    @State private var builtinSnippetCount = SnippetStorage.builtinCount()

    @State private var selectedPanel: VocabularyPanel = .hotwords
    @State private var selectedRuleReplacement: String?
    @State private var editingRuleReplacement: String?
    @State private var draftReplacement = ""
    @State private var draftTriggers: [String] = []
    @State private var draftTriggerInput = ""
    @State private var isCreatingRule = false

    var body: some View {
        GeometryReader { proxy in
            let contentHeight = max(
                0,
                proxy.size.height - SettingsControlSpec.actionHeight - VocabularySettingsStyle.pageSpacing
            )

            VStack(alignment: .leading, spacing: VocabularySettingsStyle.pageSpacing) {
                panelSwitch
                content
                    .frame(
                        maxWidth: .infinity,
                        minHeight: contentHeight,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            reloadVocabulary()
            selectInitialRuleIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从 Finder 改完内置文件切回 app 时,只重读内置计数(不动用户列表,避免覆盖编辑中的内容),
            // 让「内置 N 条」实时反映改动（2026-06-13 用户拍板）
            builtinHotwordCount = HotwordStorage.builtinCount()
            builtinSnippetCount = SnippetStorage.builtinCount()
        }
        .onChange(of: selectedPanel) { _, newValue in
            if newValue == .snippets {
                selectInitialRuleIfNeeded()
            }
        }
        .onChange(of: snippets.count) { _, _ in
            selectInitialRuleIfNeeded()
        }
    }
}

private extension VocabularyTab {
    // MARK: - Shell

    var panelSwitch: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsSwitchGroup(width: VocabularySettingsStyle.panelSwitchWidth, height: SettingsControlSpec.actionHeight) {
                ForEach(VocabularyPanel.allCases, id: \.rawValue) { panel in
                    SettingsSwitchOption(
                        title: panel.title,
                        isSelected: selectedPanel == panel
                    ) {
                        selectedPanel = panel
                    }
                }
            }

            Spacer(minLength: 12)

            // 页面右上角的大白话模式说明，随当前页切换（2026-06-12 用户拍板：
            // 放段切换同一行，不进卡片框内）；右侧留 10pt——下方卡片圆角内缩，
            // 文字贴边反而显得出边
            Text(panelExplanation)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var panelExplanation: String {
        switch selectedPanel {
        case .hotwords:
            return L("教 Muse 认词，提高识别概率", "Teach Muse new words for better accuracy")
        case .snippets:
            return L("错词自动改写，命中必改", "Auto-rewrite misheard words, every time")
        }
    }

    var content: some View {
        Group {
            switch selectedPanel {
            case .snippets:
                snippetWorkspace
            case .hotwords:
                hotwordWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var snippetWorkspace: some View {
        HStack(alignment: .top, spacing: VocabularySettingsStyle.workspaceGap) {
            snippetTable
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ruleEditorPanel
                .frame(width: VocabularySettingsStyle.detailPanelWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var hotwordWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            hotwordPanelHeader

            vocabularyDivider()

            // 滚动兜底（2026-06-12 窗口高度缩短时配套）：热词多行时不再挤压底部
            ScrollView(showsIndicators: false) {
                hotwordTokenGrid
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsBottomScrollFade(color: VocabularySettingsStyle.outerCardFillColor)

            vocabularyDivider()
                .padding(.top, VocabularySettingsStyle.footerDividerTopSpacing)

            HStack(alignment: .center, spacing: 12) {
                hotwordFooter
                    .frame(maxWidth: .infinity, alignment: .leading)

                hotwordAddControls
                    .frame(width: VocabularySettingsStyle.hotwordAddControlsWidth)
            }
            .padding(.top, VocabularySettingsStyle.footerTopSpacing)
        }
        .padding(VocabularySettingsStyle.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(vocabularySurfaceBackground)
    }

    var vocabularySurfaceBackground: some View {
        RoundedRectangle(cornerRadius: VocabularySettingsStyle.outerCardCornerRadius, style: .continuous)
            .fill(VocabularySettingsStyle.outerCardFillColor)
    }

    // MARK: - Snippet Rules

    var snippetTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            snippetPanelHeader
                .padding(.horizontal, VocabularySettingsStyle.surfacePadding)

            vocabularyDivider()

            snippetTableHeader
                .padding(.horizontal, VocabularySettingsStyle.ruleRowHorizontalPadding)

            vocabularyDivider()

            // 滚动兜底（2026-06-12 窗口高度缩短时配套）：规则多于一屏时可滚动
            ScrollView(showsIndicators: false) {
                // 懒加载：规则多时只渲染滚动可见的行，避免一次性全布局（2026-06-25，对齐概览页修复）
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredSnippetGroups.isEmpty {
                        VocabularyEmptyRow(message: emptySnippetMessage)
                            .padding(.horizontal, VocabularySettingsStyle.surfacePadding)
                    } else {
                        ForEach(filteredSnippetGroups) { group in
                            VocabularyRuleRow(
                                group: group,
                                isSelected: group.replacement == selectedRuleReplacement,
                                onSelect: {
                                    beginEditing(group)
                                },
                                onDelete: {
                                    removeGroup(replacement: group.replacement)
                                }
                            )

                            if group.id != filteredSnippetGroups.last?.id {
                                vocabularyDivider()
                                    .padding(.leading, VocabularySettingsStyle.surfacePadding)
                            }
                        }
                    }
                }
                .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsBottomScrollFade(color: VocabularySettingsStyle.outerCardFillColor)

            vocabularyDivider()
                .padding(.top, VocabularySettingsStyle.footerDividerTopSpacing)

            snippetFooter
                .frame(height: SettingsControlSpec.actionHeight)
                .padding(.horizontal, VocabularySettingsStyle.surfacePadding)
                .padding(.top, VocabularySettingsStyle.footerTopSpacing)
        }
        .padding(.vertical, VocabularySettingsStyle.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(vocabularySurfaceBackground)
    }

    var snippetPanelHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L("替换规则", "Replacement Rules"))
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)

            Text(L("用户添加 \(groupedSnippets.count)", "\(groupedSnippets.count) user"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)

            Spacer(minLength: 12)

            SettingsButton(variant: .primary, controlSize: .compact) {
                beginCreatingRule()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(TF.settingsFontIconSmall)
                    Text(L("新增", "Add"))
                }
            }
        }
        .frame(height: VocabularySettingsStyle.panelHeaderHeight)
    }

    var snippetTableHeader: some View {
        HStack(spacing: 0) {
            Text(L("替换为", "Replacement"))
                .frame(width: VocabularySettingsStyle.ruleReplacementColumnWidth, alignment: .leading)
            Text(L("触发词", "Triggers"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("操作", "Actions"))
                .frame(width: VocabularySettingsStyle.ruleActionsColumnWidth, alignment: .trailing)
        }
        .font(TF.settingsFontCaption)
        .foregroundStyle(TF.settingsTextTertiary)
        .frame(height: VocabularySettingsStyle.tableHeaderHeight)
    }

    var ruleEditorPanel: some View {
        VocabularyRuleEditorPanel(
            title: isCreatingRule ? L("新增规则", "New Rule") : L("编辑规则", "Edit Rule"),
            replacement: $draftReplacement,
            triggers: $draftTriggers,
            triggerInput: $draftTriggerInput,
            canSave: canSaveDraftRule,
            onRemoveTrigger: removeDraftTrigger,
            onCommit: saveDraftRule
        )
    }

    var snippetFooter: some View {
        VocabularyBuiltInFooter(
            summary: L("内置 \(builtinSnippetCount) 条纠正规则", "\(builtinSnippetCount) built-in correction rules"),
            onOpenBuiltInFile: {
                SnippetStorage.revealBuiltinInFinder()
            },
            onReload: {
                builtinSnippetCount = SnippetStorage.builtinCount()
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hotwords

    var hotwordFooter: some View {
        VocabularyBuiltInFooter(
            summary: L("内置 \(builtinHotwordCount) 条热词", "\(builtinHotwordCount) built-in terms"),
            onOpenBuiltInFile: {
                HotwordStorage.revealBuiltinInFinder()
            },
            onReload: {
                builtinHotwordCount = HotwordStorage.builtinCount()
            }
        )
    }

    var hotwordPanelHeader: some View {
        hotwordPanelTitle
        .frame(maxWidth: .infinity, minHeight: VocabularySettingsStyle.panelHeaderHeight, alignment: .leading)
        .padding(.bottom, 4)
    }

    var hotwordPanelTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L("识别热词", "Recognition Terms"))
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)

            Text(L("用户添加 \(hotwords.count)", "\(hotwords.count) user"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    var hotwordAddControls: some View {
        HStack(alignment: .center, spacing: 8) {
            vocabularyFlexibleTextField(
                prompt: L("输入热词…", "Add term…"),
                text: $newHotword
            )
            .onSubmit { addHotword() }

            // 按钮观感与替换规则页一致（2026-06-12 用户拍板）：不随输入置灰，
            // 空输入由 addHotword 的 guard 兜底
            SettingsTextButton(L("添加", "Add"), variant: .primary) {
                addHotword()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var hotwordTokenGrid: some View {
        Group {
            if filteredHotwords.isEmpty {
                VocabularyEmptyRow(message: emptyHotwordMessage)
            } else {
                WrappingHStack(spacing: 6) {
                    ForEach(filteredHotwords, id: \.self) { word in
                        VocabularyEditableToken(title: word) {
                            removeHotword(word)
                        }
                    }
                }
                .padding(.top, VocabularySettingsStyle.tokenGridTopPadding)
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived Data

    var emptySnippetMessage: String {
        L("还没有用户替换规则", "No user replacement rules yet")
    }

    var emptyHotwordMessage: String {
        L("还没有用户热词", "No user terms yet")
    }

    var groupedSnippets: [VocabularySnippetGroup] {
        VocabularySnippetGrouping.groups(for: snippets)
    }

    var filteredSnippetGroups: [VocabularySnippetGroup] {
        groupedSnippets
    }

    var filteredHotwords: [String] {
        hotwords
    }

    var trimmedDraftReplacement: String {
        draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanedDraftTriggers: [String] {
        uniqueCleanedStrings(draftTriggers)
    }

    var committableDraftTriggers: [String] {
        uniqueCleanedStrings(draftTriggers + splitTokenInput(draftTriggerInput))
    }

    var canSaveDraftRule: Bool {
        !trimmedDraftReplacement.isEmpty && !committableDraftTriggers.isEmpty
    }

    // MARK: - Actions

    func reloadVocabulary() {
        hotwords = HotwordStorage.load()
        snippets = SnippetStorage.load()
        builtinHotwordCount = HotwordStorage.builtinCount()
        builtinSnippetCount = SnippetStorage.builtinCount()
    }

    func selectInitialRuleIfNeeded() {
        guard selectedPanel == .snippets else { return }
        if let selectedRuleReplacement,
           groupedSnippets.contains(where: { $0.replacement == selectedRuleReplacement }) {
            return
        }
        if let first = filteredSnippetGroups.first ?? groupedSnippets.first {
            beginEditing(first)
        } else {
            beginCreatingRule()
        }
    }

    func beginCreatingRule() {
        selectedPanel = .snippets
        selectedRuleReplacement = nil
        editingRuleReplacement = nil
        draftReplacement = ""
        draftTriggers = []
        draftTriggerInput = ""
        isCreatingRule = true
    }

    func beginEditing(_ group: VocabularySnippetGroup) {
        selectedRuleReplacement = group.replacement
        editingRuleReplacement = group.replacement
        draftReplacement = group.replacement
        draftTriggers = group.triggers.map(SnippetStorage.displayTrigger)
        draftTriggerInput = ""
        isCreatingRule = false
    }

    func saveDraftRule() {
        let replacement = trimmedDraftReplacement
        let triggers = committableDraftTriggers
        guard !replacement.isEmpty, !triggers.isEmpty else { return }

        let previousReplacement = editingRuleReplacement
        let snippetsOutsideCurrentRule = snippets.filter { snippet in
            guard let previousReplacement else { return true }
            return snippet.value != previousReplacement
        }
        let usedTriggers = Set(snippetsOutsideCurrentRule.map { $0.trigger.lowercased() })
        let newSnippets = triggers
            .filter { !usedTriggers.contains($0.lowercased()) }
            .map { (trigger: $0, value: replacement) }

        guard !newSnippets.isEmpty else { return }

        // 编辑既有规则时插回原位（列表顺序 = 首现顺序；anchor 之前不含本规则条目，
        // 滤除后下标不变）。此前一律追加到尾部，规则一编辑就跳到列表末尾。
        if let previousReplacement,
           let anchor = snippets.firstIndex(where: { $0.value == previousReplacement }),
           anchor <= snippetsOutsideCurrentRule.count {
            var merged = snippetsOutsideCurrentRule
            merged.insert(contentsOf: newSnippets, at: anchor)
            snippets = merged
        } else {
            snippets = snippetsOutsideCurrentRule + newSnippets
        }
        guard persistSnippetsOrReload(context: "save draft rule") else { return }
        selectedRuleReplacement = replacement
        editingRuleReplacement = replacement
        draftReplacement = replacement
        draftTriggers = newSnippets.map(\.trigger)
        draftTriggerInput = ""
        isCreatingRule = false
    }

    func removeGroup(replacement: String) {
        snippets.removeAll { $0.value == replacement }
        guard persistSnippetsOrReload(context: "remove rule group") else { return }
        if selectedRuleReplacement == replacement || editingRuleReplacement == replacement {
            selectedRuleReplacement = nil
            editingRuleReplacement = nil
        }
        selectInitialRuleIfNeeded()
    }

    func removeDraftTrigger(_ trigger: String) {
        draftTriggers.removeAll { $0 == trigger }

        // 删除即落盘（2026-06-12 用户反馈：此前只改草稿不保存，面板又无保存按钮，
        // 切页后触发词复活）。新建草稿阶段尚未入库，仍只改草稿。
        guard !isCreatingRule, let editing = editingRuleReplacement else { return }
        if cleanedDraftTriggers.isEmpty && splitTokenInput(draftTriggerInput).isEmpty {
            // 删光最后一个触发词：无触发词的规则无法存储，等同删除整条规则
            removeGroup(replacement: editing)
        } else {
            saveDraftRule()
        }
    }

    func addHotword() {
        let word = newHotword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        guard !hotwords.contains(where: { $0.lowercased() == word.lowercased() }) else {
            newHotword = ""
            return
        }
        hotwords.insert(word, at: 0)  // 新词置顶:在用户词里排最前,下发 ASR 时权重最高（2026-06-13 用户拍板）
        guard persistHotwordsOrReload(context: "add hotword") else { return }
        newHotword = ""
    }

    func removeHotword(_ word: String) {
        hotwords.removeAll { $0 == word }
        _ = persistHotwordsOrReload(context: "remove hotword")
    }

    func persistSnippetsOrReload(context: String) -> Bool {
        do {
            try SnippetStorage.save(snippets)
            return true
        } catch {
            AppLogger.log("[VocabularyTab] \(context) failed: \(error.localizedDescription)")
            snippets = SnippetStorage.load()
            selectInitialRuleIfNeeded()
            return false
        }
    }

    func persistHotwordsOrReload(context: String) -> Bool {
        do {
            try HotwordStorage.save(hotwords)
            return true
        } catch {
            AppLogger.log("[VocabularyTab] \(context) failed: \(error.localizedDescription)")
            hotwords = HotwordStorage.load()
            return false
        }
    }

    func splitTokenInput(_ input: String) -> [String] {
        input
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func uniqueCleanedStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
        }
        return result
    }
}

private struct VocabularyRuleRow: View {
    let group: VocabularySnippetGroup
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        SettingsPlainButton(action: onSelect) {
            HStack(alignment: .center, spacing: 0) {
                Text(group.replacement)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(isSelected || isHovered ? TF.settingsText : TF.settingsTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: VocabularySettingsStyle.ruleReplacementColumnWidth, alignment: .leading)

                HStack(spacing: 6) {
                    Text(triggerSummary)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if hiddenTriggerCount > 0 {
                        SettingsChip(
                            "+\(hiddenTriggerCount)",
                            controlSize: .compact,
                            font: TF.settingsFontCaption,
                            foreground: TF.settingsTextTertiary,
                            fill: TF.settingsGhostActionFill,
                            horizontalPadding: 7,
                            height: VocabularySettingsStyle.compactTokenHeight
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MinimalRuleDeleteButton(action: onDelete)
                .opacity(isHovered || isSelected ? 1 : 0.70)
                .frame(width: VocabularySettingsStyle.ruleActionsColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, VocabularySettingsStyle.ruleRowHorizontalPadding)
            .frame(height: VocabularySettingsStyle.ruleRowHeight)
            .background {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                        .fill(isSelected ? TF.settingsSelectionFill : TF.settingsSidebarRowHoverFill.opacity(0.65))
                        .padding(.horizontal, VocabularySettingsStyle.ruleRowSelectionHorizontalInset)
                        .padding(.vertical, VocabularySettingsStyle.ruleRowSelectionVerticalInset)
                }
            }
            .contentShape(Rectangle())
        }
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }

    private var displayTriggers: [String] {
        group.triggers.map(SnippetStorage.displayTrigger)
    }

    private var visibleTriggers: [String] {
        Array(displayTriggers.prefix(VocabularySettingsStyle.visibleTriggerLimit))
    }

    private var triggerSummary: String {
        visibleTriggers.joined(separator: " · ")
    }

    private var hiddenTriggerCount: Int {
        max(displayTriggers.count - VocabularySettingsStyle.visibleTriggerLimit, 0)
    }
}

private struct MinimalRuleDeleteButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(TF.settingsFontIconSmall)
                .foregroundStyle(isHovered ? TF.settingsAccentRed : TF.settingsTextTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("删除", "Delete"))
        .accessibilityLabel(L("删除", "Delete"))
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }
}

private struct VocabularyRuleEditorPanel: View {
    let title: String
    @Binding var replacement: String
    @Binding var triggers: [String]
    @Binding var triggerInput: String
    let canSave: Bool
    let onRemoveTrigger: (String) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsText)
                Spacer(minLength: 0)
            }
            .frame(height: VocabularySettingsStyle.panelHeaderHeight)
            .padding(.horizontal, VocabularySettingsStyle.detailPanelPadding)

            panelDivider

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    VocabularyFieldLabel(L("替换为", "Replacement"))
                        .frame(height: VocabularySettingsStyle.tableHeaderHeight, alignment: .center)
                    // 回车即保存：替换文本与触发词同为草稿，面板无显式保存按钮
                    field(prompt: L("输入替换内容", "Replacement"), text: $replacement)
                        .onSubmit(onCommit)
                }

                VStack(alignment: .leading, spacing: 8) {
                    VocabularyFieldLabel(L("触发词", "Triggers"))
                        .padding(.top, 16)

                    if triggers.isEmpty {
                        Text(L("还没有触发词", "No triggers yet"))
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(height: VocabularySettingsStyle.compactTokenHeight)
                    } else {
                        WrappingHStack(spacing: 6) {
                            ForEach(triggers, id: \.self) { trigger in
                                VocabularyEditableToken(title: trigger) {
                                    onRemoveTrigger(trigger)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, VocabularySettingsStyle.detailPanelPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: VocabularySettingsStyle.stretchedCardBottomSpacing)

            // 底部结构与左侧列表/识别热词页同构（2026-06-12 用户拍板）：
            // 横线 + 28pt 控件行，两卡等高时底线与行自动对齐
            panelDivider
                .padding(.top, VocabularySettingsStyle.footerDividerTopSpacing)

            HStack(spacing: 8) {
                field(prompt: L("输入触发词…", "Add trigger…"), text: $triggerInput)
                    .onSubmit(onCommit)

                SettingsTextButton(L("添加", "Add"), variant: .primary) {
                    onCommit()
                }
                .disabled(!canSave)
            }
            .padding(.horizontal, VocabularySettingsStyle.detailPanelPadding)
            .padding(.top, VocabularySettingsStyle.footerTopSpacing)
        }
        .padding(.vertical, VocabularySettingsStyle.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: VocabularySettingsStyle.outerCardCornerRadius, style: .continuous)
                .fill(VocabularySettingsStyle.outerCardFillColor)
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(TF.settingsPopoverEdge.opacity(0.55))
            .frame(height: 1)
    }

    private func field(prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(TF.settingsTextTertiary))
            .textFieldStyle(.plain)
            .font(TF.settingsFontControl)
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 10)
            .frame(height: SettingsControlSpec.actionHeight)
            .background {
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(TF.settingsSecondaryActionFill)
            }
    }
}

private struct VocabularyEditableToken: View {
    let title: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(TF.settingsFontCaption)
                .foregroundStyle(isHovered ? TF.settingsText : TF.settingsTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            SettingsInlineRemoveButton(action: onRemove)
        }
        .padding(.horizontal, 8)
        .frame(height: VocabularySettingsStyle.compactTokenHeight)
        .background {
            Capsule()
                .fill(isHovered ? TF.settingsAccentAmber.opacity(0.22) : VocabularySettingsStyle.vocabularyTagFillColor)
        }
        .overlay {
            Capsule()
                .stroke(isHovered ? TF.settingsAccentAmber.opacity(0.42) : Color.clear, lineWidth: 1)
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

private struct VocabularyFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsTextTertiary)
    }
}
