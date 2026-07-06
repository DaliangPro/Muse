import AppKit
import SwiftUI

enum ModelSettingsEditor: String, Identifiable {
    case asr
    case llm
    case asset

    var id: String { rawValue }
}

struct ModelSettingsEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: ModelSettingsEditor
    private let editorWidth: CGFloat = 432

    var body: some View {
        Group {
            switch editor {
            case .asr:
                ASRSettingsCard(onClose: { dismiss() })
            case .llm:
                LLMSettingsCard(onClose: { dismiss() })
            case .asset:
                AssetExtractionModelSettingsCard(onClose: { dismiss() })
            }
        }
        .frame(width: editorWidth, alignment: .topLeading)
        .settingsPopupHost()
        .frame(width: editorWidth, alignment: .topLeading)
        .background(TF.settingsCard)
        .onAppear {
            // 弹窗自动聚焦首个输入框时 AppKit 默认全选其内容，一次误敲即清空。
            // 正解：打开时不聚焦任何输入框——鼠标点进字段光标落在点击处，
            // 永不全选（Tab 切换的全选是系统标准行为，保留）。
            for delay in [0.05, 0.25, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Self.clearInitialFieldFocus()
                }
            }
        }
    }

    private static func clearInitialFieldFocus() {
        for window in NSApp.windows where window.isKeyWindow || window.isSheet {
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
    }
}

struct AssetExtractionModelSettingsCard: View, SettingsCardHelpers {
    let onClose: (() -> Void)?
    @State private var footerActionsWidth: CGFloat?
    private var controlWidth: CGFloat {
        footerActionsWidth ?? ModelSettingsStyle.inspectorControlWidth
    }
    @State private var selectedProvider: LLMProvider = KeychainService.selectedAssetExtractionLLMProvider
    @State private var modelOverride: String = ""
    @State private var saveStatus: SettingsTestStatus = .idle
    @State private var credentialValues: [String: String] = [:]
    @State private var savedValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var hasStoredCreds = false
    @State private var testStatus: SettingsTestStatus = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var fetchedModels: [String] = []
    @State private var modelFetchStatus: SettingsTestStatus = .idle
    @State private var modelFetchTask: Task<Void, Never>?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedProvider.rawValue },
            set: {
                guard let provider = LLMProvider(rawValue: $0) else { return }
                selectedProvider = provider
            }
        )
    }

    private var providerOptions: [(value: String, label: String)] {
        LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
    }

    private var currentFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedProvider)?.credentialFields ?? []
    }

    private var effectiveValues: [String: String] {
        var result = savedValues
        for key in editedFields {
            result[key] = credentialValues[key] ?? ""
        }
        return result
    }

    private var requiredFieldsFilled: Bool {
        let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentFields.filter { !$0.isOptional }.allSatisfy { field in
            if field.key == "model", !override.isEmpty { return true }
            return !(effectiveValues[field.key] ?? "").isEmpty
        }
    }

    private var isConfigured: Bool {
        if selectedProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable
        }
        return requiredFieldsFilled
    }

    private var localEngineRunning: Bool {
        SenseVoiceServerManager.currentQwen3Port != nil
            || SenseVoiceServerManager.currentPort != nil
    }

    private var defaultModelName: String {
        if selectedProvider == .localQwen {
            return LocalQwenLLMConfig.availableModel?.displayName ?? "Qwen3"
        }
        return KeychainService.loadLLMCredentials(for: selectedProvider)?["model"] ?? L("沿用该服务商默认模型", "Use provider default model")
    }

    var body: some View {
        settingsGroupCard(
            L("语料沉淀", "Corpus Extraction"),
            trailing: AnyView(cardTrailing),
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            headerBottomSpacing: ModelSettingsStyle.headerBottomSpacing,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            VStack(spacing: ModelSettingsStyle.inspectorRowSpacing) {
                settingsInspectorRow(
                    L("服务商", "Provider"),
                    labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                    rowHeight: ModelSettingsStyle.inspectorRowHeight,
                    horizontalPadding: 0
                ) {
                    settingsInspectorInlineDropdown(
                        selection: providerSelection,
                        options: providerOptions,
                        width: controlWidth,
                        height: ModelSettingsStyle.inspectorFieldHeight
                    )
                }
                .zIndex(2)

                LLMCredentialRows(
                    selectedProvider: selectedProvider,
                    fields: currentFields.filter { $0.key != "model" },
                    credentialValues: $credentialValues,
                    savedValues: savedValues,
                    editedFields: $editedFields,
                    hasCredentials: requiredFieldsFilled,
                    isEditing: true,
                    localModelDisplayName: LocalQwenLLMConfig.availableModel?.displayName
                        ?? L("未检测到本地模型", "No local model found"),
                    localStatusText: localEngineRunning
                        ? L("运行中", "Running")
                        : L("未启动", "Not running"),
                    localStatusColor: localEngineRunning
                        ? TF.settingsAccentGreen
                        : TF.settingsAccentAmber,
                    controlWidth: controlWidth
                )
                .zIndex(Double(currentFields.count + 2))

                settingsInspectorRow(
                    L("模型", "Model"),
                    labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                    rowHeight: ModelSettingsStyle.inspectorRowHeight,
                    horizontalPadding: 0
                ) {
                    settingsInspectorInlineField(
                        text: $modelOverride,
                        prompt: defaultModelName,
                        width: controlWidth,
                        height: ModelSettingsStyle.inspectorFieldHeight
                    )
                }
                .zIndex(1)

                if selectedProvider != .localQwen, !fetchedModels.isEmpty {
                    settingsInspectorRow(
                        L("可选模型", "Models"),
                        labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                        rowHeight: ModelSettingsStyle.inspectorRowHeight,
                        horizontalPadding: 0
                    ) {
                        settingsInspectorInlineDropdown(
                            selection: Binding(
                                get: { modelOverride },
                                set: { modelOverride = $0 }
                            ),
                            options: fetchedModels.map { ($0, $0) },
                            width: controlWidth,
                            height: ModelSettingsStyle.inspectorFieldHeight
                        )
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    Group {
                        if modelFetchStatus == .testing {
                            Text(L("正在获取模型列表…", "Fetching models…"))
                                .foregroundStyle(TF.settingsTextTertiary)
                        } else if case .failed(let message) = modelFetchStatus {
                            Text(message)
                                .foregroundStyle(TF.settingsAccentAmber)
                        } else if !fetchedModels.isEmpty {
                            Text(L("共 \(fetchedModels.count) 个模型，选择后记得保存", "\(fetchedModels.count) models — remember to save"))
                                .foregroundStyle(TF.settingsTextTertiary)
                        } else {
                            Text(L("只适用语料沉淀", "Only applies to corpus extraction"))
                                .foregroundStyle(TF.settingsTextTertiary)
                        }
                    }
                    .font(TF.settingsFontMetadata)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        if selectedProvider != .localQwen {
                            SettingsTextButton(
                                L("获取模型列表", "Fetch Models"),
                                variant: .secondary,
                                action: fetchModelList
                            )
                        }

                        testButton(L("测试连接", "Test"), status: testStatus, action: testConnection)

                        saveButton(L("保存", "Save"), status: saveStatus, action: save)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: SettingsFooterActionsWidthKey.self, value: proxy.size.width)
                        }
                    )
                }
                .padding(.top, 12)
            }
        }
        .onPreferenceChange(SettingsFooterActionsWidthKey.self) { width in
            footerActionsWidth = width > 0 ? width : nil
        }
        .task {
            load()
        }
        .onChange(of: selectedProvider) { _, newProvider in
            modelOverride = KeychainService.loadAssetExtractionModelOverride(for: newProvider) ?? ""
            saveStatus = .idle
            testStatus = .idle
            fetchedModels = []
            modelFetchStatus = .idle
            loadCredentials(for: newProvider)
        }
    }

    @ViewBuilder
    private var cardTrailing: some View {
        if let onClose {
            SettingsIconButton(
                systemName: "xmark",
                accessibilityLabel: L("关闭", "Close"),
                variant: .ghost,
                action: onClose
            )
        } else {
            settingsHeaderStatus(
                title: isConfigured ? L("已配置", "Configured") : L("待配置", "Needs Setup"),
                color: isConfigured ? TF.settingsAccentGreen : TF.settingsAccentAmber
            )
        }
    }

    private func load() {
        selectedProvider = KeychainService.selectedAssetExtractionLLMProvider
        modelOverride = KeychainService.loadAssetExtractionModelOverride(for: selectedProvider) ?? ""
        loadCredentials(for: selectedProvider)
    }

    private func currentFieldsFor(_ provider: LLMProvider) -> [CredentialField] {
        LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
    }

    private static func displayValues(
        from values: [String: String],
        fields: [CredentialField]
    ) -> [String: String] {
        var result = values
        for field in fields where (result[field.key] ?? "").isEmpty && !field.defaultValue.isEmpty {
            result[field.key] = field.defaultValue
        }
        return result
    }

    private func loadCredentials(for provider: LLMProvider) {
        editedFields = []
        if let values = KeychainService.loadLLMCredentials(for: provider) {
            credentialValues = Self.displayValues(from: values, fields: currentFieldsFor(provider))
            savedValues = values
            hasStoredCreds = true
        } else {
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            credentialValues = CredentialDefaultValues.values(from: fields)
            savedValues = [:]
            hasStoredCreds = false
        }
    }

    private func testConnection() {
        let provider = selectedProvider
        let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        testTask?.cancel()
        testStatus = .testing

        var config: LLMConfig?
        if provider == .localQwen {
            config = KeychainService.loadAssetExtractionLLMConfig()
        } else {
            config = LLMProviderRegistry.configType(for: provider)?
                .init(credentials: effectiveValues)?.toLLMConfig()
        }
        if var resolved = config, !override.isEmpty {
            resolved = LLMConfig(apiKey: resolved.apiKey, model: override, baseURL: resolved.baseURL)
            config = resolved
        }

        testTask = Task {
            guard let config else {
                await MainActor.run {
                    recordTestOutcome(.failed(provider == .localQwen
                        ? L("本地引擎未启动", "Local engine not running")
                        : L("请先填写必填凭证", "Fill required credentials first")), provider: provider)
                }
                return
            }
            do {
                let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)
                _ = try await client.process(text: "hi", prompt: "{text}", config: config)
                await MainActor.run { recordTestOutcome(.success, provider: provider) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { recordTestOutcome(.failed(error.localizedDescription), provider: provider) }
            }
        }
    }

    private func recordTestOutcome(_ status: SettingsTestStatus, provider: LLMProvider) {
        testStatus = status
        ModelConnectivityCache.asset = (provider, status)
    }

    private func fetchModelList() {
        let provider = selectedProvider
        let values = effectiveValues
        modelFetchTask?.cancel()
        modelFetchStatus = .testing
        modelFetchTask = Task {
            do {
                let models = try await LLMModelListFetcher.fetchModels(
                    provider: provider,
                    apiKey: values["apiKey"] ?? "",
                    baseURL: values["baseURL"] ?? ""
                )
                await MainActor.run {
                    fetchedModels = models
                    modelFetchStatus = .idle
                }
            } catch {
                await MainActor.run {
                    fetchedModels = []
                    modelFetchStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func save() {
        let previousProvider = KeychainService.selectedAssetExtractionLLMProvider
        do {
            if selectedProvider != .localQwen {
                var credsToSave = effectiveValues
                let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                if (credsToSave["model"] ?? "").isEmpty, !override.isEmpty {
                    credsToSave["model"] = override
                }
                try KeychainService.saveLLMCredentials(for: selectedProvider, values: credsToSave)
                savedValues = credsToSave
                credentialValues = effectiveValues
                editedFields = []
                hasStoredCreds = true
            }
            KeychainService.selectedAssetExtractionLLMProvider = selectedProvider
            try KeychainService.saveAssetExtractionModelOverride(modelOverride, for: selectedProvider)
            testStatus = .idle
            saveStatus = .idle
            Task { @MainActor in saveStatus = .saved }
            if previousProvider != selectedProvider,
               ModelConnectivityCache.asset?.provider != selectedProvider {
                ModelConnectivityCache.asset = (selectedProvider, .idle)
            }
            AppStartupCoordinator.startLocalServerIfNeeded()
        } catch {
            saveStatus = .failed(L("保存失败", "Save failed"))
        }
    }
}
