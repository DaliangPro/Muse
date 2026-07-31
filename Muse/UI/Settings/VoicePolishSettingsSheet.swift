import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoicePolishSettingsSheet: View {
    let onClose: () -> Void

    @AppStorage(DefaultsKeys.voicePolishQualityMode)
    private var qualityRaw = VoicePolishQualityMode.balanced.rawValue
    @AppStorage(DefaultsKeys.voicePolishContextLevel)
    private var contextRaw = WritingContextLevel.metadataOnly.rawValue
    @AppStorage(DefaultsKeys.voicePolishPersonalizationEnabled)
    private var personalizationEnabled = false
    @AppStorage(DefaultsKeys.voicePolishCorrectionLimit)
    private var correctionLimit = VoicePolishSettings.defaultCorrectionLimit

    @State private var lexicon = PersonalLexiconDocument.empty
    @State private var corrections: [VoicePolishCorrectionRecord] = []
    @State private var candidates: [AutomaticLexiconCandidate] = []
    @State private var sceneOverrides: [String: WritingScene] = [:]
    @State private var overrideBundleID = ""
    @State private var overrideScene = WritingScene.unknown
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var pendingDestructiveAction: DestructiveAction?

    private let historyStore = HistoryStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("语音润色设置", "Voice Polish Settings"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)
                Spacer()
                SettingsIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("关闭", "Close"),
                    action: onClose
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.35)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    qualitySection
                    contextSection
                    personalizationSection
                    lexiconSection
                    sceneOverrideSection

                    if !statusMessage.isEmpty || !errorMessage.isEmpty {
                        Text(errorMessage.isEmpty ? statusMessage : errorMessage)
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(errorMessage.isEmpty ? TF.settingsAccentGreen : TF.settingsAccentRed)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 560, height: 680)
        .background(TF.settingsCanvas)
        .task { await reload() }
        .onChange(of: correctionLimit) { _, newValue in
            correctionLimit = min(max(1, newValue), VoicePolishSettings.maximumCorrectionLimit)
        }
        .onChange(of: personalizationEnabled) { _, enabled in
            if enabled {
                Task { await reloadLearningData() }
            } else {
                corrections = []
                candidates = []
            }
        }
        .alert(item: $pendingDestructiveAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(L("确认", "Confirm"))) {
                    Task { await perform(action) }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private extension VoicePolishSettingsSheet {
    enum DestructiveAction: String, Identifiable {
        case clearLexicon
        case resetLearning

        var id: String { rawValue }
        var title: String {
            switch self {
            case .clearLexicon: return L("清空个人词典", "Clear personal lexicon")
            case .resetLearning: return L("重置个性化学习", "Reset personalization")
            }
        }
        var message: String {
            switch self {
            case .clearLexicon:
                return L("将清空 Voice Polish 个人词典文件。原 snippet 不会被删除。", "This clears the Voice Polish lexicon file. Original snippets are preserved.")
            case .resetLearning:
                return L("将清空全部纠正样本，并同步清除派生风格画像和自动词典候选。", "This clears all corrections, derived style profiles, and automatic lexicon candidates.")
            }
        }
    }

    var qualitySection: some View {
        settingsSection(L("质量档位", "Quality")) {
            Picker("", selection: $qualityRaw) {
                Text(L("快速", "Fast")).tag(VoicePolishQualityMode.fast.rawValue)
                Text(L("均衡", "Balanced")).tag(VoicePolishQualityMode.balanced.rawValue)
                Text(L("质量", "Quality")).tag(VoicePolishQualityMode.quality.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(L(
                "快速最多 1 次调用；均衡按复杂度路由；质量档会把含改口、枚举或较长的 Structured 输入提升为 Deep。",
                "Fast uses at most one call; Balanced follows complexity; Quality promotes correction, list, and longer Structured inputs to Deep."
            ))
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    var contextSection: some View {
        settingsSection(L("写作上下文与隐私", "Writing context & privacy")) {
            Picker("", selection: $contextRaw) {
                Text(L("仅元数据", "Metadata only")).tag(WritingContextLevel.metadataOnly.rawValue)
                Text(L("选中文本", "Selected text")).tag(WritingContextLevel.selectedText.rawValue)
                Text(L("附近正文", "Nearby text")).tag(WritingContextLevel.nearbyText.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(L(
                "默认只发送应用、控件角色和场景。启用正文后，只有 AX 明确安全的标准输入框才会读取；密码框、WebArea、未知或读取失败的控件一律不读。附近正文最多取光标前后各 400 字，并可能发送给当前 LLM Provider。",
                "By default only app, role, and scene metadata are sent. Body access requires an explicitly safe standard AX field; secure, WebArea, unknown, or failed controls are blocked. Nearby text is capped at 400 characters on each side and may be sent to the current LLM provider."
            ))
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var personalizationSection: some View {
        settingsSection(L("个性化学习", "Personalization")) {
            Toggle(L("启用明确纠正学习", "Enable explicit correction learning"), isOn: $personalizationEnabled)
                .toggleStyle(.switch)

            HStack {
                Text(L("纠正记录上限", "Correction limit"))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
                Stepper(value: $correctionLimit, in: 1...VoicePolishSettings.maximumCorrectionLimit) {
                    Text("\(correctionLimit)")
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .fixedSize()
            }

            Text(profileSummary)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)

            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("待确认词典候选", "Lexicon candidates"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextSecondary)
                    ForEach(candidates) { candidate in
                        HStack {
                            Text("\(candidate.alias) → \(candidate.canonical) · \(candidate.occurrenceCount)×")
                                .font(TF.settingsFontBody)
                                .foregroundStyle(TF.settingsTextSecondary)
                            Spacer()
                            SettingsTextButton(L("确认", "Confirm"), controlSize: .compact) {
                                confirm(candidate)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                SettingsTextButton(L("导出纠正", "Export"), controlSize: .compact) {
                    Task { await exportCorrections() }
                }
                SettingsTextButton(L("重置学习", "Reset"), variant: .danger, controlSize: .compact) {
                    pendingDestructiveAction = .resetLearning
                }
            }
        }
    }

    var lexiconSection: some View {
        settingsSection(L("个人词典", "Personal lexicon")) {
            ForEach(Array(lexicon.entries.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(L("标准写法", "Canonical"), text: $lexicon.entries[index].canonical)
                        .textFieldStyle(.roundedBorder)
                    TextField(
                        L("别名，用逗号分隔", "Aliases, comma separated"),
                        text: Binding(
                            get: { lexicon.entries[index].aliases.joined(separator: ", ") },
                            set: { value in
                                lexicon.entries[index].aliases = value
                                    .split(whereSeparator: { ",，".contains($0) })
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    SettingsDeleteIconButton(
                        systemName: "xmark",
                        accessibilityLabel: L("删除词条", "Delete entry")
                    ) {
                        lexicon.entries.remove(at: index)
                    }
                }
            }

            HStack(spacing: 8) {
                SettingsTextButton(L("新增词条", "Add"), controlSize: .compact) {
                    lexicon.entries.append(PersonalLexiconEntry(canonical: "", aliases: []))
                }
                SettingsTextButton(L("保存并同步 ASR", "Save & sync ASR"), variant: .primary, controlSize: .compact) {
                    saveLexicon()
                }
                SettingsTextButton(L("复制适合的 Snippet", "Copy snippets"), controlSize: .compact) {
                    copySnippets()
                }
                Spacer()
            }
            HStack(spacing: 8) {
                SettingsTextButton(L("导出词典", "Export lexicon"), controlSize: .compact) {
                    exportLexicon()
                }
                SettingsTextButton(L("清空词典", "Clear"), variant: .danger, controlSize: .compact) {
                    pendingDestructiveAction = .clearLexicon
                }
            }
        }
    }

    var sceneOverrideSection: some View {
        settingsSection(L("应用场景覆盖", "App scene overrides")) {
            HStack(spacing: 8) {
                TextField("Bundle ID", text: $overrideBundleID)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $overrideScene) {
                    ForEach(WritingScene.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
                SettingsTextButton(L("添加", "Add"), controlSize: .compact) {
                    addSceneOverride()
                }
            }
            ForEach(sceneOverrides.keys.sorted(), id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(TF.settingsFontMono)
                        .foregroundStyle(TF.settingsTextSecondary)
                    Spacer()
                    Text(sceneOverrides[bundleID]?.rawValue ?? "unknown")
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                    SettingsDeleteIconButton(
                        systemName: "xmark",
                        accessibilityLabel: L("删除覆盖", "Delete override")
                    ) {
                        sceneOverrides.removeValue(forKey: bundleID)
                        VoicePolishSettings.setSceneOverrides(sceneOverrides)
                    }
                }
            }
        }
    }

    func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 10))
    }

    var profileSummary: String {
        guard personalizationEnabled else {
            return L("关闭后不采集、不读取纠正记录，请求也不携带风格画像。", "When off, corrections are neither collected nor read, and requests carry no style profile.")
        }
        let profile = StyleProfileUpdater.mergedProfile(from: corrections, scene: .unknown)
        guard let profile else {
            return L("已有 \(corrections.count) 条确认纠正；至少 5 条形成全局画像，单场景至少 3 条。", "\(corrections.count) confirmed correction(s); 5 create a global profile and 3 create a scene profile.")
        }
        return L(
            "画像样本 \(profile.sampleCount)：简洁 \(axis(profile.brevity))、正式 \(axis(profile.formality))、分段 \(axis(profile.paragraphing))、列表 \(axis(profile.listPreference))。",
            "Profile samples \(profile.sampleCount): brevity \(axis(profile.brevity)), formality \(axis(profile.formality)), paragraphs \(axis(profile.paragraphing)), lists \(axis(profile.listPreference))."
        )
    }

    func axis(_ value: Double) -> String { String(format: "%+.2f", value) }

    @MainActor
    func reload() async {
        lexicon = PersonalLexiconStorage.load()
        sceneOverrides = VoicePolishSettings.sceneOverrides()
        if personalizationEnabled {
            await reloadLearningData()
        } else {
            corrections = []
            candidates = []
        }
    }

    @MainActor
    func reloadLearningData() async {
        corrections = (try? await historyStore.fetchVoicePolishCorrections(
            limit: VoicePolishSettings.correctionLimit()
        )) ?? []
        candidates = StyleProfileUpdater.lexiconCandidates(from: corrections)
    }

    func saveLexicon() {
        do {
            try PersonalLexiconStorage.save(lexicon)
            lexicon = PersonalLexiconStorage.load()
            showStatus(L("个人词典已保存并同步到支持的 ASR。", "Lexicon saved and synced to supported ASR providers."))
        } catch { showError(error) }
    }

    func copySnippets() {
        do {
            let count = try PersonalLexiconStorage.copyEligibleSnippets()
            UserDefaults.standard.set(true, forKey: DefaultsKeys.voicePolishSnippetMigrationCompleted)
            lexicon = PersonalLexiconStorage.load()
            showStatus(L("已非破坏性复制 \(count) 条，原 snippet 保持不变。", "Copied \(count) item(s) non-destructively; original snippets are unchanged."))
        } catch { showError(error) }
    }

    func confirm(_ candidate: AutomaticLexiconCandidate) {
        lexicon.entries.append(PersonalLexiconEntry(
            canonical: candidate.canonical,
            aliases: [candidate.alias],
            source: .correctionCandidate
        ))
        saveLexicon()
        candidates.removeAll { $0.id == candidate.id }
    }

    func addSceneOverride() {
        let bundleID = overrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        sceneOverrides[bundleID] = overrideScene
        VoicePolishSettings.setSceneOverrides(sceneOverrides)
        overrideBundleID = ""
        showStatus(L("场景覆盖已保存。", "Scene override saved."))
    }

    @MainActor
    func exportCorrections() async {
        do {
            let data = try await historyStore.exportVoicePolishCorrections()
            try save(data: data, suggestedName: "voice-polish-corrections.json")
        } catch { showError(error) }
    }

    func exportLexicon() {
        do {
            try save(
                data: PersonalLexiconStorage.exportData(),
                suggestedName: "voice-polish-lexicon.json"
            )
        } catch { showError(error) }
    }

    @MainActor
    func save(data: Data, suggestedName: String) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
        showStatus(L("已导出。", "Exported."))
    }

    @MainActor
    func perform(_ action: DestructiveAction) async {
        do {
            switch action {
            case .clearLexicon:
                try PersonalLexiconStorage.clear()
                lexicon = .empty
                showStatus(L("个人词典已清空，原 snippet 未删除。", "Personal lexicon cleared; original snippets were preserved."))
            case .resetLearning:
                try await historyStore.deleteAllVoicePolishCorrections()
                corrections = []
                candidates = []
                showStatus(L("纠正记录、风格画像和自动候选已重置。", "Corrections, style profile, and automatic candidates were reset."))
            }
        } catch { showError(error) }
    }

    func showStatus(_ message: String) {
        errorMessage = ""
        statusMessage = message
    }

    func showError(_ error: Error) {
        statusMessage = ""
        errorMessage = error.localizedDescription
    }
}
