import SwiftUI

struct CandidateEditSheet: View {
    let candidate: LanguageAssetCandidateRecord
    let onCancel: () -> Void
    let onSave: (LanguageAssetCandidateRecord) -> Void

    @State private var assetType: LanguageAssetType
    @State private var grade: LanguageAssetGrade
    @State private var title: String
    @State private var content: String
    @State private var summary: String
    @State private var reason: String
    @State private var scenesText: String
    @State private var audiencesText: String

    init(
        candidate: LanguageAssetCandidateRecord,
        onCancel: @escaping () -> Void,
        onSave: @escaping (LanguageAssetCandidateRecord) -> Void
    ) {
        self.candidate = candidate
        self.onCancel = onCancel
        self.onSave = onSave
        _assetType = State(initialValue: candidate.assetType)
        _grade = State(initialValue: candidate.grade)
        _title = State(initialValue: candidate.title)
        _content = State(initialValue: candidate.content)
        _summary = State(initialValue: candidate.summary ?? "")
        _reason = State(initialValue: candidate.reason)
        _scenesText = State(initialValue: candidate.scenes.joined(separator: "、"))
        _audiencesText = State(initialValue: candidate.audiences.joined(separator: "、"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("编辑候选", "Edit candidate"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            VStack(alignment: .leading, spacing: 12) {
                editableField(
                    L("标题", "Title"),
                    text: $title,
                    height: 34
                )

                editableField(
                    L("内容", "Content"),
                    text: $content,
                    height: 190,
                    multiline: true
                )
            }

            Spacer(minLength: 0)

            HStack {
                Text(L("保存后仍留在待确认，可再点入库", "Saved changes stay in review."))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
                SettingsTextButton(L("保存", "Save"), variant: .primary) {
                    onSave(editedCandidate)
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.55)
            }
        }
        .padding(18)
        .frame(width: 460, height: 392, alignment: .topLeading)
        .background(TF.settingsCanvas)
    }

    private var canSave: Bool {
        !trimmed(title).isEmpty &&
            !trimmed(content).isEmpty &&
            !trimmed(reason).isEmpty
    }

    private var editedCandidate: LanguageAssetCandidateRecord {
        LanguageAssetCandidateRecord(
            id: candidate.id,
            createdAt: candidate.createdAt,
            updatedAt: Date(),
            assetType: assetType,
            grade: grade,
            title: trimmed(title),
            content: trimmed(content),
            summary: optionalText(summary),
            reason: trimmed(reason),
            scenes: splitTags(scenesText),
            audiences: splitTags(audiencesText),
            ruleHit: candidate.ruleHit,
            sourceRecordIDs: candidate.sourceRecordIDs,
            sourceRecordCount: candidate.sourceRecordCount,
            extractionJobID: candidate.extractionJobID,
            status: .pending
        )
    }

    private func editableField(
        _ title: String,
        text: Binding<String>,
        height: CGFloat,
        multiline: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            Group {
                if multiline {
                    TextField("", text: text, axis: .vertical)
                        .lineLimit(2...8)
                } else {
                    TextField("", text: text)
                        .lineLimit(1)
                }
            }
            .textFieldStyle(.plain)
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                    .fill(TF.settingsCardAlt)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(TF.settingsFontMetadata)
            .foregroundStyle(TF.settingsTextTertiary)
            .padding(.leading, 2)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalText(_ value: String) -> String? {
        let normalized = trimmed(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func splitTags(_ value: String) -> [String] {
        let separators: Set<Character> = [",", "，", "、", ";", "；", "\n"]
        var result: [String] = []
        for part in value.split(whereSeparator: { separators.contains($0) }) {
            let tag = trimmed(String(part))
            guard !tag.isEmpty, !result.contains(tag) else { continue }
            result.append(tag)
        }
        return Array(result.prefix(8))
    }
}
