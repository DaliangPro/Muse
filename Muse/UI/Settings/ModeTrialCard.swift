import SwiftUI

/// 测试 Prompt 卡（2026-06-13 重构为左右对照）：顶部工具行（测试/恢复/保存样例）
/// + 下方左右两列——左「输入」原文、右「输出结果」,各撑满下半高度,润色/翻译
/// 前后一眼对照。与上方 Prompt 块同款设计语言、等宽。
struct ModeTrialCard: View {
    let mode: ProcessingMode
    let name: String
    let processingLabel: String
    let prompt: String
    let hotkeyStyle: ProcessingMode.HotkeyStyle
    /// 测试区高度（由 ModeDetailInner 按实际工作区几何传入）
    let blockHeight: CGFloat

    @State private var trialInput = ""
    @State private var trialOutput = ""
    @State private var trialError = ""
    @State private var isRunningTrial = false
    @State private var didSaveSampleFlash = false

    /// 标准测试文案（2026-06-12 用户拍板定稿）：真实语音输入的口语原文
    /// （带口头重复、补充改口），清理/润色效果一测便知
    static var standardSampleText: String { L(
        "今天我有三件事要做。第一个是我要给自己买一个沙发套。第二个是我希望 把我下一周的稿子都集中写完，至少也要把选题写完。第三个就是就是 就是把快递都拿了。哦，再补充一个事吧，就是 给自己选一身适合健身穿的衣服。",
        "I have three things to do today. First, um, I need to buy a sofa cover. Second I want to, like, finish all of next week's drafts, or at least the topic outlines. Third is just just, just pick up the packages. Oh, one more thing, get myself an outfit that works for the gym."
    ) }

    /// Prompt 优化模式：给一段粗糙指令，优化效果立现
    static var promptOptimizeSampleText: String { L(
        "帮我写一篇关于时间管理的文章，要求写得好一点，吸引人一些，最好能让读者看完就想转发。",
        "Write me an article about time management, make it good and engaging, ideally something readers want to share."
    ) }

    /// 翻译模式：一段书面中文，译文质量一目了然
    static var translateSampleText: String { L(
        "这款产品的核心价值在于，把你每天的语音输入自动沉淀为可复用的创作素材，让灵感不再流失。",
        "把你每天的语音输入自动沉淀为可复用的创作素材，让灵感不再流失——这就是这款产品的核心价值。"
    ) }

    /// 分模式默认样例（2026-06-12 用户拍板）
    static func defaultSample(for mode: ProcessingMode) -> String {
        if mode.isPromptOptimizeMode { return promptOptimizeSampleText }
        if mode.isTranslateMode { return translateSampleText }
        return standardSampleText
    }

    private static func savedSampleKey(for mode: ProcessingMode) -> String {
        "tf_modeTrialSample_\(mode.id.uuidString)"
    }

    /// 用户保存过的自定义样例优先，否则用该模式的默认样例
    static func effectiveSample(for mode: ProcessingMode) -> String {
        UserDefaults.standard.string(forKey: savedSampleKey(for: mode)) ?? defaultSample(for: mode)
    }

    static func saveSample(_ text: String, for mode: ProcessingMode) {
        UserDefaults.standard.set(text, forKey: savedSampleKey(for: mode))
    }

    var body: some View {
        // 无标题行（2026-07-08 大梁老师）：左右两列各自「标签 → 横线 → 内容」，
        // 两条横线随列间距在中间断开；测试按钮在输出列右下角。
        // 中间用间隙分栏（不画竖线，沿用「不靠线条勾勒」的设计语言）
        HStack(alignment: .top, spacing: 0) {
            trialInputColumn
            trialOutputColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(
            width: ModeSettingsLayout.modeWorkspaceWidth,
            height: blockHeight,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .fill(fieldFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .stroke(fieldStroke, lineWidth: 1)
        }
        .onAppear {
            trialInput = Self.effectiveSample(for: mode)
        }
        .onChange(of: mode.id) { _, _ in
            trialInput = Self.effectiveSample(for: mode)
            clearResult()
        }
    }
}

private extension ModeTrialCard {
    /// 列内「标签 → 横线」，与 Prompt 块同款分隔语言
    func columnDivider() -> some View {
        Rectangle()
            .fill(fieldStroke)
            .frame(height: 1)
    }

    /// 左列：输入原文（可编辑），与 Prompt 编辑器同组件同字号
    var trialInputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("输入", "Input"))
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 2)

            columnDivider()

            ZStack(alignment: .topLeading) {
                ModeTextArea(
                    text: $trialInput,
                    isEditable: true
                )
                .id(mode.id)

                if trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L("输入一段测试文本...", "Enter sample text..."))
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.leading, 1)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)

            // 保存样例 + 恢复 钉在输入框左下角（2026-06-13 用户拍板）；
            // 保存样例与顶部「测试」按钮等大（同 width、同尺寸,只靠主次色区分）
            HStack(spacing: 8) {
                SettingsTextButton(
                    didSaveSampleFlash ? L("已保存", "Saved") : L("保存样例", "Save"),
                    variant: .secondary,
                    width: ModeSettingsLayout.modePromptSaveButtonWidth
                ) {
                    Self.saveSample(trialInput, for: mode)
                    didSaveSampleFlash = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        didSaveSampleFlash = false
                    }
                }
                .disabled(trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                SettingsIconButton(
                    systemName: "arrow.counterclockwise",
                    accessibilityLabel: L("恢复测试文案", "Restore sample text"),
                    variant: .ghost,
                    size: ModeSettingsLayout.modePromptRestoreButtonSize
                ) {
                    trialInput = Self.effectiveSample(for: mode)
                    clearResult()
                }
                .help(L("恢复测试样例", "Restore the sample text"))

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, ModeSettingsLayout.modeGutter)
        .padding(.trailing, ModeSettingsLayout.modeGutter / 2)
        .padding(.vertical, ModeSettingsLayout.modeSampleVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 右列：输出结果（只读，常驻占位）。标题右侧挂调用状态/错误提示，不占额外行
    var trialOutputColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("输出结果", "Output"))
                    .font(TF.settingsFontBodyLarge)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize()

                Spacer(minLength: 8)

                if isRunningTrial || !trialError.isEmpty {
                    trialStatusLine
                }
            }
            .padding(.bottom, 2)

            columnDivider()

            ZStack(alignment: .topLeading) {
                ModeTextArea(
                    text: .constant(trialOutput),
                    isEditable: false
                )

                if trialOutput.isEmpty {
                    Text(L("测试输出会显示在这里...", "Output will appear here..."))
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.leading, 1)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)

            // 测试 + ✕清空 靠左，与左列「保存样例 + ↺」同构；测试与其他按钮同色
            // （2026-07-08 大梁老师）
            HStack(spacing: 8) {
                SettingsTextButton(
                    isRunningTrial ? L("测试中", "Testing") : L("测试", "Test"),
                    variant: .secondary,
                    width: ModeSettingsLayout.modePromptSaveButtonWidth
                ) {
                    Task { await runTrial() }
                }
                .disabled(!canRunTrial || isRunningTrial)
                .opacity((canRunTrial && !isRunningTrial) ? 1 : 0.62)

                SettingsIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("清空输出", "Clear output"),
                    variant: .ghost,
                    size: ModeSettingsLayout.modePromptRestoreButtonSize
                ) {
                    clearResult()
                }
                .disabled(trialOutput.isEmpty && trialError.isEmpty)
                .help(L("清空输出", "Clear the output"))

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, ModeSettingsLayout.modeGutter / 2)
        .padding(.trailing, ModeSettingsLayout.modeGutter)
        .padding(.vertical, ModeSettingsLayout.modeSampleVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 调用状态/错误提示，挂在「输出结果」标题右侧：不单独占行
    var trialStatusLine: some View {
        HStack(spacing: 6) {
            if isRunningTrial {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(trialError.isEmpty ? L("调用中...", "Calling...") : trialError)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(trialError.isEmpty ? TF.settingsTextTertiary : TF.settingsAccentAmber)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    var canRunTrial: Bool {
        !trialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var fieldFill: Color {
        TF.settingsCardAlt
    }

    var fieldStroke: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.isDark {
                return NSColor.white.withAlphaComponent(0.035)
            }
            return NSColor(
                srgbRed: 25 / 255,
                green: 31 / 255,
                blue: 41 / 255,
                alpha: 0.045
            )
        }))
    }

    func runTrial() async {
        let input = trialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunningTrial else { return }

        isRunningTrial = true
        clearResult()
        defer { isRunningTrial = false }

        var draftMode = mode
        draftMode.name = name
        draftMode.processingLabel = processingLabel
        draftMode.prompt = prompt
        draftMode.hotkeyStyle = hotkeyStyle

        guard !draftMode.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trialOutput = input
            return
        }

        let context = PromptContext(selectedText: "", clipboardText: "")
        let expandedPrompt = draftMode.applyingLLMFormatGuard(
            to: context.expandContextVariables(draftMode.prompt)
        )

        guard let llmConfig = KeychainService.loadLLMConfig() else {
            trialError = L("当前 LLM 没有可用配置", "Current LLM is not configured")
            return
        }

        let provider = KeychainService.selectedLLMProvider
        let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)

        do {
            let result = try await client.process(
                text: input,
                prompt: expandedPrompt,
                config: llmConfig
            )
            let cleaned = draftMode.applyingLLMResultCleanup(to: result)
            trialOutput = cleaned.isEmpty ? L("模型返回为空", "The model returned an empty response") : cleaned
        } catch {
            trialError = error.localizedDescription
        }
    }

    func clearResult() {
        trialOutput = ""
        trialError = ""
    }
}
