import SwiftUI

struct CandidateDetailPanel: View {
    let candidate: LanguageAssetCandidateRecord?
    let displayDate: String?
    /// 已忽略池视图：动作从「忽略/入库」换成「恢复待审」（改造方案 #5）
    var isIgnoredView: Bool = false
    let onShowSources: (LanguageAssetCandidateRecord) -> Void
    var onUpdate: (LanguageAssetCandidateRecord) -> Void = { _ in }
    let onIgnore: (LanguageAssetCandidateRecord) -> Void
    let onSave: (LanguageAssetCandidateRecord) -> Void
    var onRestore: (LanguageAssetCandidateRecord) -> Void = { _ in }

    @State private var draftText = ""
    @State private var draftCandidate: LanguageAssetCandidateRecord?
    @FocusState private var isContentFocused: Bool

    var body: some View {
        Group {
            if let candidate {
                detailContent(for: candidate)
            } else {
                emptyState
            }
        }
        .onAppear {
            loadDraft(from: candidate)
        }
        .onChange(of: candidate?.id) { _, _ in
            commitDraft()
            loadDraft(from: candidate)
        }
        .onChange(of: candidate?.content) { _, _ in
            guard !isContentFocused else { return }
            loadDraft(from: candidate)
        }
        .onChange(of: isContentFocused) { _, focused in
            if !focused {
                commitDraft()
            }
        }
        .onDisappear {
            commitDraft()
        }
    }

    private func detailContent(for candidate: LanguageAssetCandidateRecord) -> some View {
        let displayCandidate = currentDraftCandidate(for: candidate)

        return VStack(alignment: .leading, spacing: 0) {
            AssetLibraryDetailHeader(
                accentColor: candidate.assetType.settingsAccentColor,
                metadata: "\(L("金句候选", "Quote candidate")) · \(displayDate ?? AssetLibraryDateFormatters.displayDateTime(candidate.createdAt))",
                grade: candidate.grade
            )
            .frame(height: AssetLibraryStyle.detailHeaderHeight, alignment: .center)
            .padding(.bottom, AssetLibraryStyle.detailSectionSpacing)

            Text(displayCandidate.title)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineLimit(2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: AssetLibraryStyle.detailTitleHeight, alignment: .topLeading)

            candidateBody(for: candidate)
                .padding(.top, AssetLibraryStyle.detailSectionSpacing)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            bottomInfo(for: candidate)
        }
        .padding(.top, AssetLibraryStyle.detailTopPadding)
        .padding(.leading, AssetLibraryStyle.detailLeadingPadding)
        .padding(.trailing, AssetLibraryStyle.discoverPanelPadding)
        .padding(.bottom, AssetLibraryStyle.discoverPanelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func candidateBody(for candidate: LanguageAssetCandidateRecord) -> some View {
        if isIgnoredView {
            ScrollView(showsIndicators: false) {
                Text(candidate.content)
                    .font(TF.settingsFontReading)
                    .foregroundStyle(TF.settingsText)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsBottomScrollFade(color: TF.settingsCard)
        } else {
            TextEditor(text: $draftText)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                        .fill(TF.settingsCardAlt.opacity(0.78))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                        .stroke(
                            isContentFocused
                                ? candidate.assetType.settingsAccentColor.opacity(0.65)
                                : TF.settingsStroke.opacity(0.22),
                            lineWidth: 1
                        )
                }
                .focused($isContentFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func bottomInfo(for candidate: LanguageAssetCandidateRecord) -> some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.detailFooterTopPadding) {
            let tags = combinedTags(scenes: candidate.scenes, audiences: candidate.audiences)
            if !tags.isEmpty {
                Text(tags.prefix(5).joined(separator: " · "))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    AssetLibraryGradeBadge(grade: candidate.grade, style: .compact)
                    Text(footerHint())
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Spacer(minLength: 0)

                SettingsTextButton(L("原始输入", "Source"), variant: .secondary) {
                    onShowSources(candidate)
                }

                if isIgnoredView {
                    SettingsTextButton(L("恢复待审", "Restore"), variant: .primary) {
                        onRestore(candidate)
                    }
                } else {
                    SettingsTextButton(L("忽略", "Ignore"), variant: .secondary) {
                        onIgnore(candidate)
                    }

                    SettingsTextButton(L("入库", "Save"), variant: .primary) {
                        onSave(currentDraftCandidate(for: candidate))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: AssetLibraryStyle.detailFooterMinHeight, alignment: .center)
        }
        .padding(.top, AssetLibraryStyle.detailFooterTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TF.settingsStroke.opacity(0.55))
                .frame(height: 1)
        }
    }

    private func footerHint() -> String {
        if isIgnoredView {
            return L("已忽略，可恢复待审", "Ignored — restorable")
        }
        return L("内容可直接修改", "Content is directly editable")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isIgnoredView ? L("没有已忽略的候选", "No ignored candidates") : L("暂无候选资产", "No candidates"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)
            Text(isIgnoredView
                ? L("被忽略的候选会保留在这里，可随时恢复。", "Ignored candidates stay here, restorable anytime.")
                : L("点击提炼后，新候选会显示在这里。", "Run extraction to see candidates here."))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(.top, 15)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func combinedTags(scenes: [String], audiences: [String]) -> [String] {
        AssetLibraryTagSorting.sortedCombinedTags(
            scenes: scenes,
            audiences: audiences,
            limit: 5
        )
    }

    private func loadDraft(from candidate: LanguageAssetCandidateRecord?) {
        draftCandidate = candidate
        draftText = candidate?.content ?? ""
    }

    private func commitDraft() {
        guard !isIgnoredView, let base = draftCandidate else { return }
        let edited = currentDraftCandidate(for: base)
        guard edited.content != base.content || edited.title != base.title else { return }

        onUpdate(edited)
        draftCandidate = edited
        draftText = edited.content
    }

    private func currentDraftCandidate(for candidate: LanguageAssetCandidateRecord) -> LanguageAssetCandidateRecord {
        guard !isIgnoredView, draftCandidate?.id == candidate.id else {
            return candidate
        }

        let trimmedContent = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return candidate
        }

        return LanguageAssetCandidateRecord(
            id: candidate.id,
            createdAt: candidate.createdAt,
            updatedAt: Date(),
            assetType: candidate.assetType,
            grade: candidate.grade,
            title: title(from: trimmedContent, fallback: candidate.title),
            content: trimmedContent,
            summary: candidate.summary,
            reason: candidate.reason,
            scenes: candidate.scenes,
            audiences: candidate.audiences,
            ruleHit: candidate.ruleHit,
            sourceRecordIDs: candidate.sourceRecordIDs,
            sourceRecordCount: candidate.sourceRecordCount,
            extractionJobID: candidate.extractionJobID,
            status: candidate.status
        )
    }

    private func title(from content: String, fallback: String) -> String {
        let normalized = content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !normalized.isEmpty else { return fallback }
        let prefix = normalized.prefix(30)
        return prefix.count < normalized.count ? "\(prefix)..." : String(prefix)
    }

}
