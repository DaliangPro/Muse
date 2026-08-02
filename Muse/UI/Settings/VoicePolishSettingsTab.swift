import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Voice Polish 的唯一产品级设置入口。
///
/// 输入模式页只负责快捷键与触发方式；这里负责附加 Prompt、响应方式、
/// 上下文和表达学习，避免两个编辑器相互覆盖。
struct VoicePolishSettingsTab: View, SettingsCardHelpers {
    var showsIntroduction = true

    @Environment(AppState.self) private var appState
    @AppStorage(DefaultsKeys.voicePolishQualityMode)
    private var qualityRaw = VoicePolishQualityMode.balanced.rawValue
    @AppStorage(DefaultsKeys.voicePolishContextLevel)
    private var contextRaw = WritingContextLevel.metadataOnly.rawValue
    @AppStorage(DefaultsKeys.voicePolishPersonalizationEnabled)
    private var styleLearningEnabled = false
    @AppStorage(DefaultsKeys.voicePolishCorrectionLimit)
    private var correctionLimit = VoicePolishSettings.defaultCorrectionLimit
    @AppStorage(DefaultsKeys.selectedLLMProvider)
    private var selectedLLMProviderRaw = LLMProvider.doubao.rawValue

    @State private var mode = ProcessingMode.formalWriting
    @State private var prompt = ""
    @State private var corrections: [VoicePolishCorrectionRecord] = []
    @State private var sceneOverrides: [String: WritingScene] = [:]
    @State private var overrideBundleID = ""
    @State private var overrideScene = WritingScene.unknown
    @State private var modelOverride = VoicePolishSettings.modelOverride() ?? ""
    @State private var terminologyLearningEnabled = VoicePolishSettings.terminologyLearningEnabled()
    @State private var recentInputContextEnabled = VoicePolishSettings.recentInputContextEnabled()
    @State private var contextDiagnostic = VoicePolishContextDiagnostics.latest()
    @State private var performanceSummary = VoicePolishPerformanceStore.summary()
    @State private var performanceSampleCount = VoicePolishPerformanceStore.samples().count
    @State private var saveTask: Task<Void, Never>?
    @State private var saveStatus = ""
    @State private var errorMessage = ""
    @State private var isResetConfirmationPresented = false

    private let historyStore = HistoryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsIntroduction {
                introduction
            }
            promptCard
            responseCard
            contextCard
            learningCard
            modelCard
            trialCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await reload() }
        .onChange(of: prompt) { _, newValue in
            schedulePromptSave(newValue)
        }
        .onChange(of: correctionLimit) { _, newValue in
            correctionLimit = min(
                max(1, newValue),
                VoicePolishSettings.maximumCorrectionLimit
            )
        }
        .onChange(of: styleLearningEnabled) { _, enabled in
            if enabled {
                Task { await reloadCorrections() }
            }
        }
        .onChange(of: terminologyLearningEnabled) { _, enabled in
            VoicePolishSettings.setTerminologyLearningEnabled(enabled)
        }
        .onChange(of: recentInputContextEnabled) { _, enabled in
            VoicePolishSettings.setRecentInputContextEnabled(enabled)
        }
        .onChange(of: modelOverride) { _, value in
            VoicePolishSettings.setModelOverride(value)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modesDidChange)) { _ in
            guard saveTask == nil else { return }
            reloadMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePolishContextDiagnosticsDidChange)) { _ in
            contextDiagnostic = VoicePolishContextDiagnostics.latest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voicePolishPerformanceDidChange)) { _ in
            reloadPerformanceSummary()
        }
        .onDisappear {
            flushPromptSave()
        }
        .alert(L("重置表达学习", "Reset style learning"), isPresented: $isResetConfirmationPresented) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("重置", "Reset"), role: .destructive) {
                Task { await resetStyleLearning() }
            }
        } message: {
            Text(L(
                "这会删除用于学习表达习惯的纠正样本，但不会删除“术语与纠错”中的已确认术语。",
                "This deletes correction samples used for writing style. Confirmed terms in Terminology are preserved."
            ))
        }
    }
}

private extension VoicePolishSettingsTab {
    var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsAccentAmber)
                    .accessibilityHidden(true)
                Text(L("让语音直接成为可发送的文字", "Turn speech into send-ready writing"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)
            }

            Text(L(
                "Muse 负责事实安全、术语保护和失败回退；你仍可自由定义语气、简洁度与格式。",
                "Muse protects facts, terminology, and safe fallback. You stay in control of tone, brevity, and formatting."
            ))
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var promptCard: some View {
        settingsGroupCard(
            L("我的附加润色要求", "My additional polishing requirements"),
            icon: "text.badge.plus",
            titleAccessory: AnyView(promptStatusView),
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(
                    "可选。这里控制语气、简洁度和格式，不需要在 Prompt 里重复编写术语纠正或事实保护规则。",
                    "Optional. This controls tone, brevity, and formatting; terminology correction and fact protection are handled by Muse."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    ModeTextArea(text: $prompt, isEditable: true)
                        .accessibilityLabel(L("附加润色要求", "Additional polishing requirements"))

                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(L(
                            "例如：保留我的口语感，表达简洁，不要随便使用列表。",
                            "For example: Keep my natural voice, stay concise, and avoid unnecessary lists."
                        ))
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                        .padding(.leading, 1)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: 142)
                .padding(.horizontal, 10)
                .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    SettingsTextButton(L("恢复默认", "Restore Default"), controlSize: .compact) {
                        prompt = ProcessingMode.formalWriting.prompt
                    }
                    Spacer(minLength: 0)
                    Text(L("输入后自动保存", "Saves automatically"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }
        }
    }

    @ViewBuilder
    var promptStatusView: some View {
        if !errorMessage.isEmpty {
            SettingsChip(
                L("保存失败", "Save failed"),
                controlSize: .compact,
                font: TF.settingsFontMetadata,
                foreground: TF.settingsAccentRed,
                fill: TF.settingsDangerFill
            )
            .help(errorMessage)
        } else if !saveStatus.isEmpty {
            SettingsChip(
                saveStatus,
                controlSize: .compact,
                font: TF.settingsFontMetadata,
                foreground: TF.settingsAccentGreen,
                fill: TF.settingsSuccessFill
            )
        }
    }

    var responseCard: some View {
        settingsGroupCard(
            L("响应方式", "Response mode"),
            icon: "speedometer",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSwitchGroup(width: nil) {
                    ForEach(VoicePolishQualityMode.allCases, id: \.rawValue) { quality in
                        SettingsSwitchOption(
                            title: qualityTitle(quality),
                            isSelected: qualityRaw == quality.rawValue
                        ) {
                            qualityRaw = quality.rawValue
                        }
                        .accessibilityHint(qualityDescription(quality))
                        .accessibilityAddTraits(qualityRaw == quality.rawValue ? .isSelected : [])
                        .accessibilityValue(qualityRaw == quality.rawValue
                            ? L("已选择", "Selected")
                            : L("未选择", "Not selected"))
                    }
                }

                Text(qualityDescription(selectedQuality))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var contextCard: some View {
        settingsGroupCard(
            L("上下文与隐私", "Context & privacy"),
            icon: "lock.shield",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSwitchGroup(width: nil) {
                    ForEach(contextLevels, id: \.rawValue) { level in
                        SettingsSwitchOption(
                            title: contextTitle(level),
                            isSelected: contextRaw == level.rawValue
                        ) {
                            contextRaw = level.rawValue
                        }
                        .accessibilityHint(contextDescription(level))
                        .accessibilityAddTraits(contextRaw == level.rawValue ? .isSelected : [])
                        .accessibilityValue(contextRaw == level.rawValue
                            ? L("已选择", "Selected")
                            : L("未选择", "Not selected"))
                    }
                }

                Text(contextDescription(selectedContextLevel))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle()
                    .fill(TF.settingsStroke.opacity(0.55))
                    .frame(height: 1)

                Toggle(isOn: $recentInputContextEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("参考 Muse 最近输入", "Reference recent Muse input"))
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsText)
                        Text(L(
                            "仅使用 Muse 在同一应用最近 3 次、15 分钟内的输入；只保存在内存中，不读取完整聊天，也不跨应用。",
                            "Uses only the last 3 Muse inputs from the same app within 15 minutes. It stays in memory, never reads full chats, and never crosses apps."
                        ))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                    Text(L(
                        "“附近文字”只指当前安全输入框光标前后各最多 400 字，不是完整聊天记录。密码框、WebArea、未知控件和读取失败时一律不读取正文。",
                        "Nearby text means up to 400 characters on each side of the cursor in the current safe text field—not full chat history. Secure fields, WebArea, unknown controls, and read failures never expose body text."
                    ))
                }
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

                contextDiagnosticStatus
            }
        }
    }

    var learningCard: some View {
        settingsGroupCard(
            L("纠正与学习", "Corrections & learning"),
            icon: "person.text.rectangle",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $terminologyLearningEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("记住我明确确认的术语修改", "Remember term edits I explicitly confirm"))
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsText)
                        Text(L(
                            "例如把“Type less”纠正为“Typeless”。这与表达风格学习相互独立，并可在每次纠正时取消。",
                            "For example, correcting “Type less” to “Typeless.” This is independent from style learning and can be deselected for each correction."
                        ))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $styleLearningEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("从我明确确认的修改中学习表达习惯", "Learn writing style from edits I explicitly confirm"))
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsText)
                        Text(L(
                            "只影响简洁度、正式度、分段和列表偏好；术语记忆在确认时单独选择。",
                            "Only affects brevity, formality, paragraphs, and list preferences. Term memory is chosen separately when confirming a correction."
                        ))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                    }
                }
                .toggleStyle(.switch)

                if styleLearningEnabled {
                    HStack(spacing: 12) {
                        Text(profileSummary)
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsTextSecondary)
                        Spacer(minLength: 8)
                        Stepper(value: $correctionLimit, in: 1...VoicePolishSettings.maximumCorrectionLimit) {
                            Text(L("最多 \(correctionLimit) 条", "Keep up to \(correctionLimit)"))
                                .font(TF.settingsFontCaption)
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }

                    HStack(spacing: 8) {
                        SettingsTextButton(L("导出纠正记录", "Export Corrections"), controlSize: .compact) {
                            Task { await exportCorrections() }
                        }
                        .disabled(corrections.isEmpty)
                        SettingsTextButton(L("重置表达学习", "Reset Style Learning"), variant: .danger, controlSize: .compact) {
                            isResetConfirmationPresented = true
                        }
                        .disabled(styleCorrections.isEmpty)
                        SettingsTextButton(L("前往识别记录", "Open Recognition History"), controlSize: .compact) {
                            NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.general)
                        }
                    }
                } else {
                    Text(L(
                        "关闭后不会读取这些纠正样本，也不会把风格画像发送给模型；已经确认的术语仍然生效。",
                        "When off, correction samples are not read and no style profile is sent to the model. Confirmed terminology still works."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                }

                SettingsTextButton(L("管理术语与纠错", "Manage Terminology"), controlSize: .compact) {
                    NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.vocabulary)
                }

                DisclosureGroup(L("按应用指定写作场景", "Writing scene overrides by app")) {
                    sceneOverridesEditor
                        .padding(.top, 10)
                }
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
            }
        }
    }

    var contextDiagnosticStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: contextDiagnostic == nil ? "clock" : "checkmark.circle")
                .font(TF.settingsFontIconSmall)
                .foregroundStyle(contextDiagnostic == nil ? TF.settingsTextTertiary : TF.settingsAccentGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("最近一次实际使用", "Latest actual use"))
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsTextSecondary)
                Text(contextDiagnosticDescription)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))
    }

    var sceneOverridesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Bundle ID", text: $overrideBundleID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("应用 Bundle ID", "App bundle ID"))
                    .accessibilityHint(L(
                        "请输入反向域名格式，例如 com.openai.chat",
                        "Enter a reverse-domain identifier such as com.openai.chat"
                    ))
                Picker("", selection: $overrideScene) {
                    ForEach(WritingScene.allCases, id: \.self) { scene in
                        Text(sceneTitle(scene)).tag(scene)
                    }
                }
                .labelsHidden()
                .frame(width: 138)
                .accessibilityLabel(L("写作场景", "Writing scene"))
                .accessibilityValue(sceneTitle(overrideScene))
                SettingsTextButton(L("添加", "Add"), controlSize: .compact) {
                    addSceneOverride()
                }
                .disabled(!TerminologyBundleIdentifierValidator.isValid(overrideBundleID))
            }

            if !overrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !TerminologyBundleIdentifierValidator.isValid(overrideBundleID) {
                Text(L(
                    "Bundle ID 格式无效，请使用 com.company.app 这类反向域名格式。",
                    "Invalid Bundle ID. Use reverse-domain format such as com.company.app."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsAccentRed)
            }

            ForEach(sceneOverrides.keys.sorted(), id: \.self) { bundleID in
                HStack(spacing: 8) {
                    Text(bundleID)
                        .font(TF.settingsFontMono)
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(sceneTitle(sceneOverrides[bundleID] ?? .unknown))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                    SettingsDeleteIconButton(
                        systemName: "xmark",
                        accessibilityLabel: L("删除场景覆盖", "Delete scene override")
                    ) {
                        sceneOverrides.removeValue(forKey: bundleID)
                        VoicePolishSettings.setSceneOverrides(sceneOverrides)
                    }
                }
            }
        }
    }

    var modelCard: some View {
        settingsGroupCard(
            L("模型与速度", "Model & speed"),
            icon: "cpu",
            expandVertically: false
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedLLMProvider.displayName)
                            .font(TF.settingsFontBodyStrong)
                            .foregroundStyle(TF.settingsText)
                        Text(modelStatusDescription)
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(modelIsConfigured ? TF.settingsTextTertiary : TF.settingsAccentAmber)
                    }
                    Spacer(minLength: 12)
                    SettingsTextButton(L("前往模型配置", "Open Model Config"), controlSize: .compact) {
                        NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.models)
                    }
                }

                Rectangle()
                    .fill(TF.settingsStroke.opacity(0.55))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("专用快速模型（可选）", "Dedicated fast model (optional)"))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsText)

                    HStack(spacing: 8) {
                        TextField(
                            globalModelName.isEmpty
                                ? L("留空则跟随全局模型", "Leave blank to follow the global model")
                                : L("留空则使用 \(globalModelName)", "Leave blank to use \(globalModelName)"),
                            text: $modelOverride
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L("语音润色专用快速模型", "Dedicated Voice Polish fast model"))

                        SettingsTextButton(L("跟随全局", "Use Global"), controlSize: .compact) {
                            modelOverride = ""
                        }
                        .disabled(modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text(L(
                        "只覆写模型名，仍复用当前 Provider、API Key 和服务地址。请填写同一 Provider 确实支持的快速模型；填错时会安全回退到已纠正的识别文本。",
                        "Only the model name is overridden. The current provider, API key, and endpoint are reused. Use a supported fast model; failures safely fall back to the corrected transcript."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle()
                    .fill(TF.settingsStroke.opacity(0.55))
                    .frame(height: 1)

                performanceStatus
            }
        }
    }

    @ViewBuilder
    var performanceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("最近真实表现", "Recent actual performance"))
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)

            if let performanceSummary {
                HStack(spacing: 6) {
                    SettingsChip(
                        L("单次完成 \(percent(performanceSummary.singleCallRate))", "Single-call \(percent(performanceSummary.singleCallRate))"),
                        controlSize: .compact,
                        font: TF.settingsFontMetadata,
                        foreground: TF.settingsTextSecondary
                    )
                    SettingsChip(
                        L("修复 \(percent(performanceSummary.repairRate))", "Repair \(percent(performanceSummary.repairRate))"),
                        controlSize: .compact,
                        font: TF.settingsFontMetadata,
                        foreground: TF.settingsTextSecondary
                    )
                    SettingsChip(
                        L("回退 \(percent(performanceSummary.fallbackRate))", "Fallback \(percent(performanceSummary.fallbackRate))"),
                        controlSize: .compact,
                        font: TF.settingsFontMetadata,
                        foreground: TF.settingsTextSecondary
                    )
                }

                ForEach(performanceSummary.routes, id: \.route.rawValue) { route in
                    HStack(spacing: 8) {
                        Text(performanceRouteTitle(route.route))
                            .font(TF.settingsFontCaption)
                            .foregroundStyle(TF.settingsTextSecondary)
                            .frame(width: 74, alignment: .leading)
                        Text("P50 \(durationText(route.p50Milliseconds))  ·  P95 \(durationText(route.p95Milliseconds))  ·  n=\(route.sampleCount)")
                            .font(TF.settingsFontMono)
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                }

                Text(L(
                    "基于最近 \(performanceSummary.sampleCount) 次真实语音润色请求，不包含文字试跑；这里只展示实测值，不代表目标承诺。",
                    "Based on the latest \(performanceSummary.sampleCount) real Voice Polish requests, excluding text trials. These are measured values, not target claims."
                ))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L(
                    "已积累 \(performanceSampleCount)/\(VoicePolishPerformanceStore.minimumVisibleSampleCount) 次真实请求；样本足够后再显示 P50、P95、修复率和回退率。",
                    "Collected \(performanceSampleCount)/\(VoicePolishPerformanceStore.minimumVisibleSampleCount) real requests. P50, P95, repair rate, and fallback rate appear only after enough samples."
                ))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var trialCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("文字试跑", "Text trial"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)
                SettingsChip(
                    L("不包含语音识别", "ASR not included"),
                    controlSize: .compact,
                    font: TF.settingsFontMetadata,
                    foreground: TF.settingsAccentAmber,
                    fill: TF.settingsWarningFill
                )
                Spacer(minLength: 0)
            }

            Text(L(
                "这里只验证术语处理后的文字成稿与 LLM 链路。要验证麦克风和真实识别，请使用语音润色快捷键完成一次实际输入。",
                "This validates writing generation from text after terminology handling. Use the Voice Polish shortcut for a real microphone and ASR test."
            ))
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize(horizontal: false, vertical: true)

            ModeTrialCard(
                mode: effectiveMode,
                name: effectiveMode.name,
                processingLabel: effectiveMode.processingLabel,
                prompt: prompt,
                hotkeyStyle: effectiveMode.hotkeyStyle,
                blockHeight: 310
            )
        }
    }

    var selectedQuality: VoicePolishQualityMode {
        VoicePolishQualityMode(rawValue: qualityRaw) ?? .balanced
    }

    var selectedContextLevel: WritingContextLevel {
        WritingContextLevel(rawValue: contextRaw) ?? .metadataOnly
    }

    var contextLevels: [WritingContextLevel] {
        [.metadataOnly, .selectedText, .nearbyText]
    }

    var selectedLLMProvider: LLMProvider {
        LLMProvider(rawValue: selectedLLMProviderRaw) ?? KeychainService.selectedLLMProvider
    }

    var modelIsConfigured: Bool {
        KeychainService.loadLLMProviderConfig(for: selectedLLMProvider) != nil
    }

    var modelStatusDescription: String {
        if modelIsConfigured {
            let override = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty {
                return L("语音润色使用专用模型：\(override)", "Voice Polish uses the dedicated model: \(override)")
            }
            if !globalModelName.isEmpty {
                return L("当前跟随全局文本处理模型：\(globalModelName)", "Following the global text model: \(globalModelName)")
            }
        }
        return L("当前模型尚未完成配置，文字试跑和正式润色将不可用。", "The current model is not configured; text trials and Voice Polish are unavailable.")
    }

    var globalModelName: String {
        KeychainService.loadLLMConfig()?.model ?? ""
    }

    var effectiveMode: ProcessingMode {
        var value = mode
        value.prompt = prompt
        return value
    }

    var styleCorrections: [VoicePolishCorrectionRecord] {
        corrections.filter(\.learnStyle)
    }

    var profileSummary: String {
        guard let profile = StyleProfileUpdater.mergedProfile(from: styleCorrections, scene: .unknown) else {
            return L(
                "已有 \(styleCorrections.count) 条表达样本；至少 5 条形成全局表达画像。",
                "\(styleCorrections.count) style sample(s); at least 5 create a global style profile."
            )
        }
        return L(
            "已根据 \(profile.sampleCount) 条样本形成表达画像。",
            "Style profile built from \(profile.sampleCount) samples."
        )
    }

    var contextDiagnosticDescription: String {
        guard let snapshot = contextDiagnostic else {
            return L(
                "尚无记录。使用一次语音润色后，这里只显示应用、上下文类型和数量，不保存正文。",
                "No record yet. After one Voice Polish use, this shows only the app, context type, and counts—never the text itself."
            )
        }
        let app = snapshot.applicationName
            ?? snapshot.applicationBundleID
            ?? L("未知应用", "Unknown app")
        let captured: String
        switch snapshot.capturedKind {
        case .metadataOnly:
            captured = L("未读取正文", "no body text read")
        case .selectedText:
            captured = L("使用选中文字 \(snapshot.selectedCharacterCount) 字", "used \(snapshot.selectedCharacterCount) selected characters")
        case .nearbyText:
            captured = L("使用输入框附近 \(snapshot.nearbyCharacterCount + snapshot.selectedCharacterCount) 字", "used \(snapshot.nearbyCharacterCount + snapshot.selectedCharacterCount) nearby characters")
        case .unavailable:
            captured = snapshot.safety == .secure
                ? L("安全输入框，未读取正文", "secure field; no body text read")
                : L("控件不可确认安全，未读取正文", "field safety unavailable; no body text read")
        }
        let recent = snapshot.recentMuseInputCount > 0
            ? L("；另参考同一应用最近 \(snapshot.recentMuseInputCount) 次 Muse 输入", "; plus \(snapshot.recentMuseInputCount) recent Muse input(s) from the same app")
            : ""
        return "\(app) · \(Self.contextDiagnosticTimeFormatter.string(from: snapshot.capturedAt)) · \(captured)\(recent)"
    }

    func qualityTitle(_ value: VoicePolishQualityMode) -> String {
        switch value {
        case .fast: return L("快速", "Fast")
        case .balanced: return L("标准（推荐）", "Standard (Recommended)")
        case .quality: return L("深度整理", "Deep")
        }
    }

    func qualityDescription(_ value: VoicePolishQualityMode) -> String {
        switch value {
        case .fast:
            return L("适合短句和即时聊天，优先减少等待。", "Best for short messages and chat, prioritizing lower wait time.")
        case .balanced:
            return L("适合大多数消息、邮件和 AI Prompt，在成稿质量与速度之间平衡。", "Best for most messages, emails, and AI prompts, balancing quality and speed.")
        case .quality:
            return L("只建议用于多次跨段改口、内容乱序或多主题的复杂口述，等待会更长。", "Use for complex dictation with cross-paragraph corrections, reordered ideas, or multiple topics. It takes longer.")
        }
    }

    func contextTitle(_ value: WritingContextLevel) -> String {
        switch value {
        case .metadataOnly: return L("不读取正文", "No body text")
        case .selectedText: return L("选中的文字", "Selected text")
        case .nearbyText: return L("输入框附近", "Nearby field text")
        }
    }

    func contextDescription(_ value: WritingContextLevel) -> String {
        switch value {
        case .metadataOnly:
            return L("只使用应用名称、控件角色和推断场景。", "Uses only the app name, control role, and inferred scene.")
        case .selectedText:
            return L("仅在安全的标准输入框中参考你明确选中的文字。", "References only text you explicitly select in a safe standard text field.")
        case .nearbyText:
            return L("在安全的标准输入框中参考光标附近文字，帮助延续语气和指代。", "References text around the cursor in a safe standard text field to maintain tone and references.")
        }
    }

    func performanceRouteTitle(_ route: VoicePolishRoute) -> String {
        switch route {
        case .fast: return L("快速", "Fast")
        case .structured: return L("标准", "Standard")
        case .deep: return L("深度整理", "Deep")
        }
    }

    func durationText(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        return String(format: "%.1fs", Double(milliseconds) / 1_000)
    }

    func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    func sceneTitle(_ scene: WritingScene) -> String {
        switch scene {
        case .chat: return L("聊天", "Chat")
        case .workChat: return L("工作沟通", "Work chat")
        case .email: return L("邮件", "Email")
        case .document: return L("文档", "Document")
        case .note: return L("笔记", "Note")
        case .aiPrompt: return "AI Prompt"
        case .code: return L("代码", "Code")
        case .socialPost: return L("社交发布", "Social post")
        case .customerSupport: return L("客户支持", "Customer support")
        case .unknown: return L("未指定", "Unspecified")
        }
    }

    @MainActor
    func reload() async {
        reloadMode()
        modelOverride = VoicePolishSettings.modelOverride() ?? ""
        terminologyLearningEnabled = VoicePolishSettings.terminologyLearningEnabled()
        recentInputContextEnabled = VoicePolishSettings.recentInputContextEnabled()
        contextDiagnostic = VoicePolishContextDiagnostics.latest()
        reloadPerformanceSummary()
        sceneOverrides = VoicePolishSettings.sceneOverrides()
        await reloadCorrections()
    }

    @MainActor
    func reloadCorrections() async {
        do {
            corrections = try await historyStore.fetchVoicePolishCorrections(
                limit: VoicePolishSettings.correctionLimit()
            )
        } catch {
            corrections = []
        }
    }

    @MainActor
    func reloadMode() {
        let loaded = ModeStorage().load()
        mode = loaded.first(where: { $0.kind == .voicePolish }) ?? .formalWriting
        prompt = mode.prompt
    }

    func schedulePromptSave(_ newPrompt: String) {
        guard newPrompt != mode.prompt else {
            saveTask?.cancel()
            saveTask = nil
            return
        }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            savePrompt(newPrompt)
            saveTask = nil
        }
    }

    func flushPromptSave() {
        saveTask?.cancel()
        saveTask = nil
        guard prompt != mode.prompt else { return }
        savePrompt(prompt)
    }

    @MainActor
    func savePrompt(_ value: String) {
        var modes = ModeStorage().load()
        guard let index = modes.firstIndex(where: { $0.kind == .voicePolish }) else {
            errorMessage = L("没有找到稳定的语音润色模式。", "The stable Voice Polish mode could not be found.")
            return
        }
        modes[index].prompt = value
        do {
            try ModeStorage().save(modes)
            mode = modes[index]
            errorMessage = ""
            saveStatus = L("已保存", "Saved")
            appState.availableModes = modes
            if appState.currentMode.id == mode.id {
                appState.currentMode = mode
            }
            NotificationCenter.default.post(name: .modesDidChange, object: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                if saveStatus == L("已保存", "Saved") {
                    saveStatus = ""
                }
            }
        } catch {
            saveStatus = ""
            errorMessage = error.localizedDescription
        }
    }

    func addSceneOverride() {
        let bundleID = overrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminologyBundleIdentifierValidator.isValid(bundleID) else { return }
        sceneOverrides[bundleID] = overrideScene
        VoicePolishSettings.setSceneOverrides(sceneOverrides)
        overrideBundleID = ""
    }

    @MainActor
    func resetStyleLearning() async {
        do {
            try await historyStore.resetVoicePolishStyleLearning()
            await reloadCorrections()
            saveStatus = L("表达学习已重置", "Style learning reset")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func reloadPerformanceSummary() {
        performanceSampleCount = VoicePolishPerformanceStore.samples().count
        performanceSummary = VoicePolishPerformanceStore.summary()
    }

    @MainActor
    func exportCorrections() async {
        do {
            let data = try await historyStore.exportVoicePolishCorrections()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Muse-Voice-Polish-Corrections-\(Self.exportDateString()).json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            saveStatus = L("已导出", "Exported")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static let contextDiagnosticTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
