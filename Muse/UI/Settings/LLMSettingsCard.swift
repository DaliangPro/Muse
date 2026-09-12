import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LLM Settings Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct LLMSettingsCard: View, SettingsCardHelpers {
    let onClose: (() -> Void)?
    /// 底排按钮组量到的实际宽度；输入框与它取齐（左右对齐）
    @State private var footerActionsWidth: CGFloat?
    private var inspectorControlWidth: CGFloat {
        footerActionsWidth ?? ModelSettingsStyle.inspectorControlWidth
    }

    @State private var selectedLLMProvider: LLMProvider = .doubao
    @State private var llmCredentialValues: [String: String] = [:]
    @State private var savedLLMValues: [String: String] = [:]
    @State private var editedFields: Set<String> = []
    @State private var llmTestStatus: SettingsTestStatus = .idle
    // 获取模型列表（2026-06-11 用户拍板新增）
    @State private var fetchedModels: [String] = []
    @State private var modelFetchStatus: SettingsTestStatus = .idle
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var isEditingLLM = true
    @State private var hasStoredLLM = false
    @State private var testTask: Task<Void, Never>?
    @State private var serverStarting = false
    @State private var serverRunning = false
    @State private var polishModelOverride = VoicePolishSettings.modelOverride() ?? ""
    @State private var thinkingMode: LLMThinkingMode = .disabled
    @State private var lockedThinkingMode: LLMThinkingMode?
    @State private var thinkingFeedback: String?
    @State private var thinkingFeedbackIsFailure = false

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private var currentLLMFields: [CredentialField] {
        LLMProviderRegistry.configType(for: selectedLLMProvider)?.credentialFields ?? []
    }

    /// Effective values: saved base + dirty edits overlaid.
    private var effectiveLLMValues: [String: String] {
        var result = savedLLMValues
        for key in editedFields {
            result[key] = llmCredentialValues[key] ?? ""
        }
        return result
    }

    private var hasLLMCredentials: Bool {
        let required = currentLLMFields.filter { !$0.isOptional }
        let effective = effectiveLLMValues
        return required.allSatisfy { field in
            !(effective[field.key] ?? "").isEmpty
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { selectedLLMProvider.rawValue },
            set: { if let provider = LLMProvider(rawValue: $0) { selectedLLMProvider = provider } }
        )
    }

    private var providerOptions: [(value: String, label: String)] {
        LLMProvider.allCases.map { ($0.rawValue, $0.displayName) }
    }

    private var headerStatusTitle: String {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable
                ? L("已配置", "Configured")
                : L("待配置", "Needs Setup")
        }
        return hasLLMCredentials
            ? L("已配置", "Configured")
            : L("待配置", "Needs Setup")
    }

    private var headerStatusColor: Color {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable ? TF.settingsAccentGreen : TF.settingsAccentAmber
        }
        return hasLLMCredentials ? TF.settingsAccentGreen : TF.settingsAccentAmber
    }

    // MARK: Body

    var body: some View {
        settingsGroupCard(
            L("文本处理", "Text Processing"),
            trailing: AnyView(cardTrailing),
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            headerBottomSpacing: ModelSettingsStyle.headerBottomSpacing,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            VStack(spacing: 0) {
                LLMProviderSelectionRow(
                    selectedProvider: selectedLLMProvider,
                    selection: providerSelection,
                    options: providerOptions,
                    isEditing: isEditingLLM,
                    controlWidth: inspectorControlWidth
                )
                .zIndex(Double(currentLLMFields.count + 1))

                LLMCredentialRows(
                    selectedProvider: selectedLLMProvider,
                    fields: currentLLMFields,
                    credentialValues: $llmCredentialValues,
                    savedValues: savedLLMValues,
                    editedFields: $editedFields,
                    hasCredentials: hasLLMCredentials,
                    isEditing: isEditingLLM,
                    localModelDisplayName: localModelDisplayName,
                    localStatusText: localStatusText,
                    localStatusColor: localStatusColor,
                    controlWidth: inspectorControlWidth
                )

                settingsInspectorRow(
                    L("润色模型", "Polish model"),
                    labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                    rowHeight: ModelSettingsStyle.inspectorRowHeight,
                    horizontalPadding: 0
                ) {
                    TextField(L("留空跟随文本处理模型", "Use text model if blank"), text: $polishModelOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: inspectorControlWidth)
                        .disabled(!isEditingLLM)
                        .help(L("可选，同一服务商下的润色专用模型名。", "Optional polishing model from the same provider."))
                }

                thinkingModeRows

                // 与 CredentialFieldRow 的只读规则对齐：已存凭证且未进入编辑时
                // 字段只读，此时选模型无处保存，故同样隐藏取数行
                if selectedLLMProvider != .localQwen, isEditingLLM || !hasLLMCredentials {
                    modelListFetchRows
                }
            }
            .zIndex(10)

            LLMSettingsFooter(
                showsCancel: onClose == nil,
                selectedProvider: selectedLLMProvider,
                hasCredentials: hasLLMCredentials,
                hasStoredCredentials: hasStoredLLM,
                isEditing: isEditingLLM,
                testStatus: llmTestStatus,
                isServerRunning: serverRunning,
                isLocalModelAvailable: LocalQwenLLMConfig.isModelAvailable,
                onFetchModels: fetchModelList,
                onTestConnection: { testLLMConnection() },
                onStopLocalServer: { stopLocalServer() },
                onStartLocalServer: { startLocalServer() },
                onEdit: {
                    testTask?.cancel()
                    llmTestStatus = .idle
                    llmCredentialValues = [:]
                    editedFields = []
                    isEditingLLM = true
                },
                onCancel: {
                    testTask?.cancel()
                    llmTestStatus = .idle
                    if let onClose {
                        // 直达编辑场景：取消即关闭弹窗、不保存任何改动
                        onClose()
                    } else {
                        loadLLMCredentials()
                    }
                },
                onSave: { saveLLMCredentials() }
            )
            .zIndex(0)
        }
        .onPreferenceChange(SettingsFooterActionsWidthKey.self) { width in
            footerActionsWidth = width > 0 ? width : nil
        }
        .task {
            loadLLMCredentials()
            await checkServerStatus()
        }
        .onChange(of: selectedLLMProvider) { oldProvider, newProvider in
            handleLLMProviderChange(from: oldProvider, to: newProvider)
            fetchedModels = []
            modelFetchStatus = .idle
        }
        .onChange(of: effectiveLLMValues) { oldValues, newValues in
            handleEffectiveValuesChange(from: oldValues, to: newValues)
        }
    }

    // MARK: - 获取模型列表（2026-06-11）

    @ViewBuilder
    private var modelListFetchRows: some View {
        if !fetchedModels.isEmpty {
            settingsInspectorRow(
                L("可选模型", "Models"),
                labelWidth: ModelSettingsStyle.inspectorLabelWidth,
                rowHeight: ModelSettingsStyle.inspectorRowHeight,
                horizontalPadding: 0
            ) {
                settingsInspectorInlineDropdown(
                    selection: fetchedModelSelection,
                    options: fetchedModels.map { ($0, $0) },
                    width: inspectorControlWidth,
                    height: ModelSettingsStyle.inspectorFieldHeight
                )
            }
        }
        if modelFetchStatus == .testing || isFetchFailed || !fetchedModels.isEmpty {
            HStack(spacing: 8) {
                if modelFetchStatus == .testing {
                    Text(L("正在获取模型列表…", "Fetching models…"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                } else if case .failed(let message) = modelFetchStatus {
                    Text(message)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsAccentAmber)
                        .lineLimit(1)
                } else {
                    Text(L("共 \(fetchedModels.count) 个模型，选择后记得保存", "\(fetchedModels.count) models — remember to save"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Spacer()
            }
        }
    }

    private var isFetchFailed: Bool {
        if case .failed = modelFetchStatus { return true }
        return false
    }

    private var fetchedModelSelection: Binding<String> {
        Binding(
            get: { effectiveLLMValues["model"] ?? "" },
            set: { picked in
                llmCredentialValues["model"] = picked
                editedFields.insert("model")
            }
        )
    }

    @ViewBuilder
    private var thinkingModeRows: some View {
        settingsInspectorRow(
            L("深度思考", "Reasoning"),
            labelWidth: ModelSettingsStyle.inspectorLabelWidth,
            rowHeight: ModelSettingsStyle.inspectorRowHeight,
            horizontalPadding: 0
        ) {
            LLMThinkingModePicker(
                mode: thinkingModeSelection,
                width: inspectorControlWidth,
                isLocked: isThinkingControlLocked
            )
        }

        if let thinkingFeedback {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: ModelSettingsStyle.inspectorLabelWidth)
                LLMThinkingFeedbackText(
                    message: thinkingFeedback,
                    isFailure: thinkingFeedbackIsFailure
                )
                .frame(width: inspectorControlWidth, alignment: .leading)
            }
        }
    }

    private var thinkingModeSelection: Binding<LLMThinkingMode> {
        Binding(
            get: { thinkingMode },
            set: { newMode in
                guard !isThinkingControlLocked else { return }
                thinkingMode = newMode
                invalidateThinkingValidation()
                if selectedLLMProvider == .localQwen {
                    persistThinkingMode(newMode)
                }
            }
        )
    }

    private var isThinkingControlLocked: Bool {
        if lockedThinkingMode != nil { return true }
        return selectedLLMProvider != .localQwen && hasStoredLLM && !isEditingLLM
    }

    private func fetchModelList() {
        let values = effectiveLLMValues
        let provider = selectedLLMProvider
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

    // MARK: - Local Qwen Status

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
            settingsHeaderStatus(title: headerStatusTitle, color: headerStatusColor)
        }
    }

    private var localModelDisplayName: String {
        if let model = LocalQwenLLMConfig.availableModel {
            return model.displayName
        }
        return L("未找到本地模型", "Model not found")
    }

    private var localStatusText: String {
        if serverStarting {
            return L("启动中", "Starting")
        }
        if serverRunning {
            return L("运行中", "Running")
        }
        return L("未启用", "Idle")
    }

    private var localStatusColor: Color {
        if serverRunning {
            return TF.settingsAccentGreen
        }
        return LocalQwenLLMConfig.isModelAvailable ? TF.settingsAccentAmber : TF.settingsAccentRed
    }

    private func startLocalServer() {
        Task { await preloadLocalLLM() }
    }

    private func checkServerStatus() async {
        serverRunning = await LocalLLMServerControl.isRunning()
    }

    /// Start server + send dummy request to trigger LLM model loading (~7-13s).
    private func preloadLocalLLM() async {
        serverStarting = true
        if await LocalLLMServerControl.preload() {
            serverRunning = true
        }
        serverStarting = false
    }

    private func stopLocalServer() {
        Task {
            let result = await LocalLLMServerControl.unloadAndStopIfUnneeded()
            if result == .stoppedServer {
                serverRunning = false
            }
        }
    }

    // MARK: - Provider Picker

    private func handleLLMProviderChange(from oldProvider: LLMProvider, to newProvider: LLMProvider) {
        testTask?.cancel()
        llmTestStatus = .idle
        isEditingLLM = true
        loadLLMCredentialsForProvider(newProvider)

        if newProvider == .localQwen || hasLLMCredentials {
            KeychainService.selectedLLMProvider = newProvider
            if newProvider == .localQwen {
                Task { await preloadLocalLLM() }
            } else if oldProvider == .localQwen {
                stopLocalServer()
                Task { await LocalLLMServerControl.stopQwen3IfASRDoesNotNeedIt() }
            }
        }
    }

    private func handleEffectiveValuesChange(
        from oldValues: [String: String],
        to newValues: [String: String]
    ) {
        guard oldValues != newValues else { return }
        if oldValues["model"] != newValues["model"] {
            loadThinkingMode(for: selectedLLMProvider)
        } else {
            invalidateThinkingValidation()
        }
    }

    // MARK: - Data


    /// 展示用值：空字段回填其默认值（如 Base URL 官方地址）。
    /// 密钥同样预填真实值——所见即所得（安全字段由系统以圆点呈现）
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

    private func loadLLMCredentials() {
        selectedLLMProvider = KeychainService.selectedLLMProvider
        loadLLMCredentialsForProvider(selectedLLMProvider)
    }

    private func loadLLMCredentialsForProvider(_ provider: LLMProvider) {
        testTask?.cancel()
        editedFields = []
        if let values = KeychainService.loadLLMCredentials(for: provider) {
            savedLLMValues = values
            hasStoredLLM = true
            llmCredentialValues = Self.displayValues(from: values, fields: currentLLMFields)
            // 弹窗场景直达编辑，字段预填真实值所见即所得
            isEditingLLM = !hasLLMCredentials || onClose != nil
        } else {
            let fields = LLMProviderRegistry.configType(for: provider)?.credentialFields ?? []
            let defaults = CredentialDefaultValues.values(from: fields)
            llmCredentialValues = defaults
            savedLLMValues = [:]
            hasStoredLLM = false
            isEditingLLM = true
        }
        loadThinkingMode(for: provider)
    }

    private var effectiveModelName: String {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.availableModel?.name ?? "qwen3.5-9b"
        }
        return (effectiveLLMValues["model"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadThinkingMode(for provider: LLMProvider) {
        thinkingMode = KeychainService.loadLLMThinkingMode(
            role: .textProcessing,
            provider: provider,
            model: effectiveModelName
        )
        lockedThinkingMode = nil
        thinkingFeedback = nil
        thinkingFeedbackIsFailure = false
        llmTestStatus = .idle
    }

    private func persistThinkingMode(_ mode: LLMThinkingMode) {
        KeychainService.saveLLMThinkingMode(
            mode,
            role: .textProcessing,
            provider: selectedLLMProvider,
            model: effectiveModelName
        )
    }

    private func invalidateThinkingValidation() {
        testTask?.cancel()
        llmTestStatus = .idle
        lockedThinkingMode = nil
        thinkingFeedback = nil
        thinkingFeedbackIsFailure = false
    }

    private func saveLLMCredentials() {
        let values = effectiveLLMValues
        let previousProvider = KeychainService.selectedLLMProvider
        do {
            try KeychainService.saveLLMCredentials(for: selectedLLMProvider, values: values)
            KeychainService.selectedLLMProvider = selectedLLMProvider
            persistThinkingMode(thinkingMode)
            VoicePolishSettings.setModelOverride(polishModelOverride)
            // REPAIR_PLAN H1 改进①：改选本地模型立即预热引擎
            AppStartupCoordinator.startLocalServerIfNeeded()
            llmCredentialValues = Self.displayValues(from: values, fields: currentLLMFields)
            savedLLMValues = values
            editedFields = []
            hasStoredLLM = true
            // 弹窗场景保存后留在编辑态：字段保持可见可改，不退回「只读+修改」模式
            isEditingLLM = onClose != nil
            // 先归零再异步置 .saved：保证连续两次保存时状态确实发生变化，按钮每次都能闪绿
            llmTestStatus = .idle
            Task { @MainActor in llmTestStatus = .saved }
            // 仅当「换了服务商且弹窗里没测过新商」才作废主页色点；原商仅保存不动连通状态
            if previousProvider != selectedLLMProvider {
                ModelConnectivityCache.llm = nil
            }

            // Preload local LLM model on save
            if selectedLLMProvider == .localQwen {
                Task { await preloadLocalLLM() }
            }
        } catch {
            llmTestStatus = .failed(L("保存失败", "Save failed"))
        }
    }

    private func testLLMConnection() {
        testTask?.cancel()
        llmTestStatus = .testing
        let testValues = effectiveLLMValues
        let provider = selectedLLMProvider
        testTask = Task {
            do {
                let llmConfig: LLMConfig
                if provider == .localQwen {
                    // LLM runs on Qwen3-ASR server (shares Metal GPU lock)
                    let port = SenseVoiceServerManager.currentQwen3Port ?? SenseVoiceServerManager.currentPort
                    guard let port else {
                        guard !Task.isCancelled else { return }
                        recordTestOutcome(
                            .failed(L("Qwen3 服务未运行，请先启动", "Qwen3 server not running, start it first")),
                            provider: provider,
                            config: nil
                        )
                        return
                    }
                    llmConfig = LLMConfig(
                        apiKey: "",
                        model: effectiveModelName,
                        baseURL: "http://127.0.0.1:\(port)/v1",
                        thinkingMode: thinkingMode
                    )
                } else {
                    guard let configType = LLMProviderRegistry.configType(for: provider),
                          let config = configType.init(credentials: testValues)
                    else {
                        guard !Task.isCancelled else { return }
                        recordTestOutcome(
                            .failed(L("配置无效", "Invalid config")),
                            provider: provider,
                            config: nil
                        )
                        return
                    }
                    llmConfig = config.toLLMConfig().withThinkingMode(thinkingMode)
                }
                let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)
                let result = await LLMThinkingModeValidator.validate(
                    provider: provider,
                    config: llmConfig,
                    client: client
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .valid:
                    lockedThinkingMode = nil
                    thinkingFeedback = nil
                    thinkingFeedbackIsFailure = false
                    recordTestOutcome(.success, provider: provider, config: llmConfig)
                    AppLogger.log("[Settings] LLM test OK (\(provider.rawValue))")
                case .adjusted(let mode, let message):
                    thinkingMode = mode
                    lockedThinkingMode = mode
                    thinkingFeedback = message
                    thinkingFeedbackIsFailure = false
                    persistThinkingMode(mode)
                    let correctedConfig = llmConfig.withThinkingMode(mode)
                    recordTestOutcome(.success, provider: provider, config: correctedConfig)
                    AppLogger.log(
                        "[Settings] LLM thinking adjusted \(llmConfig.thinkingMode.rawValue) -> \(mode.rawValue) (\(provider.rawValue))"
                    )
                case .failed(let message):
                    thinkingFeedback = message
                    thinkingFeedbackIsFailure = true
                    recordTestOutcome(.failed(message), provider: provider, config: llmConfig)
                    AppLogger.log("[Settings] LLM test failed (\(provider.rawValue)): \(message)")
                }
            }
        }
    }

    /// 测试结果同时记入回传通道，主页色点关弹窗时采纳
    private func recordTestOutcome(
        _ status: SettingsTestStatus,
        provider: LLMProvider,
        config: LLMConfig?
    ) {
        llmTestStatus = status
        if let config {
            ModelConnectivityCache.llm = LLMConnectivityCacheEntry(
                signature: LLMConnectivitySignature(provider: provider, config: config),
                status: status
            )
        } else {
            ModelConnectivityCache.llm = nil
        }
    }
}
