import SwiftUI

struct VoicePolishCorrectionSheet: View {
    let record: HistoryRecord
    let onConfirm: (String, WritingScene) async throws -> Void
    let onCancel: () -> Void

    @State private var correctedText: String
    @State private var scene = WritingScene.unknown
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(
        record: HistoryRecord,
        onConfirm: @escaping (String, WritingScene) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.record = record
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _correctedText = State(initialValue: record.finalText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("纠正并学习", "Correct and learn"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            Text(L(
                "只会学习你在这里明确确认的修改，不会监控目标 App 中的后续编辑。",
                "Only edits explicitly confirmed here are learned. Muse does not monitor later edits in the target app."
            ))
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsTextTertiary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("当前结果", "Current result"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(record.finalText)
                    .font(TF.settingsFontReading)
                    .foregroundStyle(TF.settingsTextSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("你的最终版本", "Your final version"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                TextEditor(text: $correctedText)
                    .font(TF.settingsFontReading)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 130)
                    .background(TF.settingsCardAlt, in: RoundedRectangle(cornerRadius: 8))
            }

            Picker(L("写作场景", "Writing scene"), selection: $scene) {
                ForEach(WritingScene.allCases, id: \.self) { value in
                    Text(sceneTitle(value)).tag(value)
                }
            }
            .pickerStyle(.menu)

            if !VoicePolishSettings.personalizationEnabled() {
                Text(L("个性化当前已关闭，请先在语音润色设置中开启。", "Personalization is off. Enable it in Voice Polish settings first."))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsAccentAmber)
            } else if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsAccentRed)
            }

            HStack(spacing: 8) {
                Spacer()
                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, width: 72) {
                    onCancel()
                }
                SettingsTextButton(
                    isSaving ? L("保存中", "Saving") : L("确认学习", "Confirm"),
                    variant: .primary,
                    width: 86
                ) {
                    Task { await confirm() }
                }
                .disabled(!canConfirm || isSaving)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(TF.settingsCanvas)
    }

    private var canConfirm: Bool {
        VoicePolishSettings.personalizationEnabled()
            && !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
                != record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func confirm() async {
        guard canConfirm else { return }
        isSaving = true
        errorMessage = ""
        do {
            try await onConfirm(correctedText, scene)
            onCancel()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func sceneTitle(_ scene: WritingScene) -> String {
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
}
