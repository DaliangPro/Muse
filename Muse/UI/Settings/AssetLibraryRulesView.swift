import SwiftUI

struct AssetLibraryRulesView: View {
    @Binding var ruleConfig: AssetExtractionRuleConfig
    @Binding var selectedRuleType: LanguageAssetType?
    @State private var selectedPromptRule: AssetPromptRuleSelection = .global
    @State private var isPromptRulePickerOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.sectionSpacing) {
            promptRulesModule
                .frame(maxHeight: .infinity, alignment: .topLeading)

            strategyModule
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let selectedRuleType {
                selectedPromptRule = .type(selectedRuleType)
            }
        }
    }
}

private extension AssetLibraryRulesView {
    var promptResetButtonTitle: String {
        L("恢复默认", "Reset")
    }

    var strategyModule: some View {
        ZStack(alignment: .topTrailing) {
            AssetLibraryRuleStrategyCard(ruleConfig: $ruleConfig)
                .padding(.trailing, 92)

            HStack {
                SettingsTextButton(
                    L("恢复默认", "Reset"),
                    variant: .secondary,
                    controlSize: .compact
                ) {
                    resetStrategyToDefault()
                }
            }
            .frame(height: AssetStrategyHeaderLayout.controlHeight, alignment: .center)
        }
        .padding(AssetLibraryRuleLayout.modulePadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(moduleBackground)
    }

    var promptRulesModule: some View {
        GeometryReader { proxy in
            let editorViewportHeight = AssetLibraryRuleLayout.editorViewportHeight(
                forModuleHeight: proxy.size.height
            )
            let scrollFadeVisible = promptRulesNeedScrollFade(availableHeight: editorViewportHeight)
            let editorBottomPadding = AssetLibraryRuleLayout.editorBottomPadding(
                needsScrollFade: scrollFadeVisible
            )

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: AssetLibraryRuleLayout.moduleContentSpacing) {
                    Color.clear
                        .frame(height: AssetLibraryRuleLayout.headerHeight)

                    ScrollView {
                        selectedPromptRuleEditor(availableHeight: editorViewportHeight)
                            .padding(.bottom, editorBottomPadding)
                    }
                    .settingsThinScrollIndicators()
                    .settingsBottomScrollFade(
                        color: AssetLibraryStyle.shellFill,
                        isVisible: scrollFadeVisible
                    )
                    .zIndex(0)
                }

                promptRulesHeader
                    .zIndex(isPromptRulePickerOpen ? 120 : 10)
            }
            .padding(AssetLibraryRuleLayout.modulePadding)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(moduleBackground)
        .zIndex(isPromptRulePickerOpen ? 70 : 0)
    }

    var promptRulesHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            AssetPromptRulePickerControl(
                selection: selectedPromptRule,
                isOpen: $isPromptRulePickerOpen
            ) { selection in
                selectPromptRule(selection)
            }

            Spacer(minLength: 0)

            SettingsTextButton(
                promptResetButtonTitle,
                variant: .secondary,
                controlSize: .compact
            ) {
                resetSelectedPromptRuleToDefault()
            }
        }
        .frame(height: AssetLibraryRuleLayout.headerHeight, alignment: .center)
    }

    @ViewBuilder
    func selectedPromptRuleEditor(availableHeight: CGFloat) -> some View {
        switch selectedPromptRule {
        case .global:
            globalRuleEditorContent(availableHeight: availableHeight)
        case .type(let type):
            typeRuleEditorContent(for: type)
        }
    }

    var moduleBackground: some View {
        RoundedRectangle(cornerRadius: AssetLibraryStyle.panelCornerRadius, style: .continuous)
            .fill(AssetLibraryStyle.shellFill)
    }

    func selectPromptRule(_ selection: AssetPromptRuleSelection) {
        selectedPromptRule = selection
        selectedRuleType = selection.type
        isPromptRulePickerOpen = false
    }

    func resetStrategyToDefault() {
        ruleConfig.candidateQuantity = AssetExtractionRuleConfig.default.candidateQuantity
        ruleConfig.saveThreshold = AssetExtractionRuleConfig.default.saveThreshold
        ruleConfig.priorityDirection = AssetExtractionRuleConfig.default.priorityDirection
        ruleConfig.lowValueFilter = AssetExtractionRuleConfig.default.lowValueFilter
        ruleConfig.audienceFocus = AssetExtractionRuleConfig.default.audienceFocus
    }

    func resetSelectedPromptRuleToDefault() {
        switch selectedPromptRule {
        case .global:
            ruleConfig.customPrompt = AssetExtractionRuleConfig.default.customPrompt
            ruleConfig.saveRule = AssetExtractionRuleConfig.default.saveRule
            ruleConfig.ignoreRule = AssetExtractionRuleConfig.default.ignoreRule
        case .type(let type):
            ruleConfig.typeRules[type.rawValue] = AssetExtractionRuleConfig.default.typeRule(for: type)
        }
    }

    func promptRulesNeedScrollFade(availableHeight: CGFloat) -> Bool {
        switch selectedPromptRule {
        case .global:
            let promptHeight = AssetLibraryRuleLayout.globalPromptInputHeight(
                forEditorViewportHeight: availableHeight
            )
            let criteriaHeight = AssetLibraryRuleLayout.globalCriteriaInputHeight(
                forEditorViewportHeight: availableHeight,
                promptHeight: promptHeight
            )
            return AssetLibraryRuleLayout.globalEditorContentHeight(
                promptHeight: promptHeight,
                criteriaHeight: criteriaHeight
            ) > availableHeight
        case .type:
            return AssetLibraryRuleLayout.typeEditorContentHeight > availableHeight
        }
    }

    func globalRuleEditorContent(availableHeight: CGFloat) -> some View {
        let promptHeight = AssetLibraryRuleLayout.globalPromptInputHeight(
            forEditorViewportHeight: availableHeight
        )
        // 入库/忽略框吃掉 Prompt 之外的剩余高度、自适应拉长撑满，消除 Prompt 缩短后下方的留白
        // （2026-06-25 大梁老师：拉长这两个框弥补留白，而非把空间让给策略区）
        let criteriaHeight = AssetLibraryRuleLayout.globalCriteriaInputHeight(
            forEditorViewportHeight: availableHeight,
            promptHeight: promptHeight
        )

        return VStack(alignment: .leading, spacing: AssetLibraryRuleLayout.editorContentSpacing) {
            ruleTextBlock(
                title: L("Prompt", "Prompt"),
                text: Binding(
                    get: { ruleConfig.customPrompt },
                    set: { ruleConfig.customPrompt = $0 }
                ),
                height: promptHeight
            )

            HStack(alignment: .top, spacing: 10) {
                ruleTextBlock(
                    title: L("入库标准", "Save Criteria"),
                    text: Binding(
                        get: { ruleConfig.saveRule },
                        set: { ruleConfig.saveRule = $0 }
                    ),
                    height: criteriaHeight
                )
                ruleTextBlock(
                    title: L("忽略标准", "Ignore Criteria"),
                    text: Binding(
                        get: { ruleConfig.ignoreRule },
                        set: { ruleConfig.ignoreRule = $0 }
                    ),
                    height: criteriaHeight
                )
            }
        }
    }

    func typeRuleEditorContent(for type: LanguageAssetType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ruleTextBlock(
                    title: L("定义", "Definition"),
                    text: typeRuleBinding(type: type, keyPath: \.definition),
                    height: AssetLibraryRuleLayout.typeDefinitionInputHeight
                )
                ruleTextBlock(
                    title: L("参考示例", "Example"),
                    text: typeRuleBinding(type: type, keyPath: \.example),
                    height: AssetLibraryRuleLayout.typeDefinitionInputHeight
                )
            }

            HStack(alignment: .top, spacing: 10) {
                ruleTextBlock(
                    title: L("入库标准", "Save Criteria"),
                    text: typeRuleBinding(type: type, keyPath: \.saveRule),
                    height: AssetLibraryRuleLayout.typeCriteriaInputHeight
                )
                ruleTextBlock(
                    title: L("忽略标准", "Ignore Criteria"),
                    text: typeRuleBinding(type: type, keyPath: \.ignoreRule),
                    height: AssetLibraryRuleLayout.typeCriteriaInputHeight
                )
            }
        }
    }

    func ruleTextBlock(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.leading, AssetLibraryRuleLayout.inputHorizontalPadding)

            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineLimit(2...8)
                .padding(.horizontal, AssetLibraryRuleLayout.inputHorizontalPadding)
                .padding(.vertical, 7)
                .frame(height: height, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: AssetLibraryStyle.controlCornerRadius, style: .continuous)
                        .fill(AssetLibraryRuleLayout.inputFill)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func typeRuleBinding(
        type: LanguageAssetType,
        keyPath: WritableKeyPath<AssetTypeRuleConfig, String>
    ) -> Binding<String> {
        Binding(
            get: {
                ruleConfig.typeRule(for: type)[keyPath: keyPath]
            },
            set: { newValue in
                var rule = ruleConfig.typeRule(for: type)
                rule[keyPath: keyPath] = newValue
                ruleConfig.typeRules[type.rawValue] = rule
            }
        )
    }
}

private enum AssetLibraryRuleLayout {
    static let modulePadding: CGFloat = 12
    static let moduleContentSpacing: CGFloat = 10
    static let headerHeight: CGFloat = 28
    static let editorContentSpacing: CGFloat = 10
    static let textBlockLabelHeight: CGFloat = 14
    static let textBlockLabelSpacing: CGFloat = 6
    static let inputHorizontalPadding: CGFloat = 9
    // 输入框填充：原 settingsSegmentSelectedFill 在浅色下与模块背景同为 (0.995)、完全融合看不见；
    // 改用下拉框同款填充，明暗两色都比背景深约 0.05、形成可见的「凹陷」输入区（2026-06-25）
    static let inputFill = TF.settingsDropdownTriggerFill
    static let globalPromptInputMinimumHeight: CGFloat = 150
    static let globalPromptInputMaximumHeight: CGFloat = 210
    static let secondaryInputHeight: CGFloat = 98
    static let typeDefinitionInputHeight: CGFloat = 88
    static let typeCriteriaInputHeight: CGFloat = 112

    static func editorViewportHeight(forModuleHeight moduleHeight: CGFloat) -> CGFloat {
        max(moduleHeight - modulePadding * 2 - headerHeight - moduleContentSpacing, 0)
    }

    static func globalPromptInputHeight(forEditorViewportHeight viewportHeight: CGFloat) -> CGFloat {
        let fittingHeight = viewportHeight
            - editorContentSpacing
            - textBlockHeight(forInputHeight: secondaryInputHeight)
            - textBlockLabelHeight
            - textBlockLabelSpacing

        return fittingHeight.clamped(
            to: globalPromptInputMinimumHeight...globalPromptInputMaximumHeight
        )
    }

    static func globalEditorContentHeight(promptHeight: CGFloat, criteriaHeight: CGFloat) -> CGFloat {
        textBlockHeight(forInputHeight: promptHeight)
            + editorContentSpacing
            + textBlockHeight(forInputHeight: criteriaHeight)
    }

    /// 入库/忽略框高度：吃掉 Prompt 块之外的剩余视口高度，自适应撑满消留白；不小于原最小高度
    static func globalCriteriaInputHeight(
        forEditorViewportHeight viewportHeight: CGFloat,
        promptHeight: CGFloat
    ) -> CGFloat {
        let remaining = viewportHeight
            - textBlockHeight(forInputHeight: promptHeight)
            - editorContentSpacing
            - textBlockLabelHeight
            - textBlockLabelSpacing
        return max(secondaryInputHeight, remaining)
    }

    static var typeEditorContentHeight: CGFloat {
        textBlockHeight(forInputHeight: typeDefinitionInputHeight)
            + editorContentSpacing
            + textBlockHeight(forInputHeight: typeCriteriaInputHeight)
    }

    static func textBlockHeight(forInputHeight inputHeight: CGFloat) -> CGFloat {
        textBlockLabelHeight + textBlockLabelSpacing + inputHeight
    }

    static func editorBottomPadding(needsScrollFade: Bool) -> CGFloat {
        needsScrollFade ? SettingsScrollFade.contentPadding : 0
    }
}

private enum AssetStrategyHeaderLayout {
    static let controlHeight: CGFloat = 24
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
