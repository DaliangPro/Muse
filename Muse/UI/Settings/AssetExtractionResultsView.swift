import SwiftUI

struct AssetExtractionResultsView: View {
    @Binding var resultQuery: String
    @Binding var selectedResultKind: ExtractionOutputKind?
    @Binding var selectedResultID: String?
    let results: [ExtractionResult]
    let selectedResult: ExtractionResult?
    let latestRun: ExtractionRun?
    let copiedResultID: String?
    let formattedDate: (Date) -> String
    let onShowSources: (ExtractionResult) -> Void
    let onCopyResult: (ExtractionResult) -> Void

    var body: some View {
        AssetLibrarySplitPanel {
            resultNavigationPanel
        } detail: {
            resultDetailPanel
        }
    }
}

private extension AssetExtractionResultsView {
    var resultGroups: [(kind: ExtractionOutputKind, results: [ExtractionResult])] {
        ExtractionOutputKind.allCases.compactMap { kind in
            guard kind != .assetCandidates else { return nil }
            let items = results.filter { $0.outputKind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    var expandedResultKind: ExtractionOutputKind? {
        if let selectedResultKind,
           resultGroups.contains(where: { $0.kind == selectedResultKind }) {
            return selectedResultKind
        }
        return nil
    }

    var displayedResult: ExtractionResult? {
        if let selectedResult,
           results.contains(where: { $0.id == selectedResult.id }) {
            return selectedResult
        }
        return resultGroups.first?.results.first
    }

    var resultNavigationPanel: some View {
        AssetLibraryNavigationPanel(
            query: $resultQuery,
            prompt: L("搜索结果", "Search results")
        ) {
            if results.isEmpty {
                Text(L("暂无提炼结果", "No extraction results"))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ForEach(resultGroups, id: \.kind) { group in
                    resultKindGroup(kind: group.kind, items: group.results)
                }
            }
        }
    }

    func resultKindGroup(kind: ExtractionOutputKind, items: [ExtractionResult]) -> some View {
        let isExpanded = expandedResultKind == kind

        return VStack(alignment: .leading, spacing: 5) {
            SettingsSelectableRow(
                isSelected: isExpanded,
                minHeight: TF.settingsControlHeight,
                verticalPadding: 5
            ) {
                if isExpanded {
                    selectedResultKind = nil
                } else {
                    selectedResultKind = kind
                    selectedResultID = items.first?.id
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(kind.settingsAccentColor)
                        .frame(width: 5, height: 5)
                    Text(kind.settingsDisplayTitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(items.count)")
                        .foregroundStyle(TF.settingsTextTertiary)
                    Image(systemName: "chevron.right")
                        .font(TF.settingsFontIconSmall)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 10)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(TF.settingsFontBody)
                .foregroundStyle(isExpanded ? TF.settingsText : TF.settingsTextTertiary)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationItemSpacing) {
                    ForEach(items) { result in
                        resultButton(result)
                    }
                }
            }
        }
    }

    func resultButton(_ result: ExtractionResult) -> some View {
        AssetLibraryCompactItemRow(
            title: result.title,
            grade: nil,
            isSelected: displayedResult?.id == result.id,
            isNew: latestRun?.id == result.runID
        ) {
            selectedResultID = result.id
            selectedResultKind = result.outputKind
        }
    }

    @ViewBuilder
    var resultDetailPanel: some View {
        if let result = displayedResult {
            AssetLibraryDetailPane(
                accentColor: result.outputKind.settingsAccentColor,
                metadata: "\(result.outputKind.settingsDisplayTitle) · \(formattedDate(result.createdAt))",
                grade: nil,
                title: result.title,
                bodyText: result.content,
                tags: resultTags(for: result)
            ) {
                HStack(spacing: 8) {
                    Text(L("来源 \(result.sourceRecordCount) 条", "\(result.sourceRecordCount) sources"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    SettingsTextButton(
                        L("原始输入", "Source"),
                        variant: .secondary
                    ) {
                        onShowSources(result)
                    }

                    SettingsTextButton(
                        copiedResultID == result.id ? L("已复制", "Copied") : L("复制结果", "Copy"),
                        variant: .primary
                    ) {
                        onCopyResult(result)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("暂无提炼结果", "No extraction results"))
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)
                Text(L("选择“待办”或“工作日报”提炼后，结果会显示在这里。", "Run a todo or report recipe to see results here."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.top, 15)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    func resultTags(for result: ExtractionResult) -> [String] {
        [
            result.recipeID.replacingOccurrences(of: "builtin.", with: ""),
            result.summary ?? "",
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}

struct ExtractionResultSourceRecordsSheet: View {
    let result: ExtractionResult
    let records: [HistoryRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.title)
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            if records.isEmpty {
                Text(L("没有找到原始输入记录。", "No source records found."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(records, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(formatDate(record.createdAt))
                                    .font(TF.settingsFontMono)
                                    .foregroundStyle(TF.settingsTextTertiary)
                                Text(record.finalText)
                                    .font(TF.settingsFontReading)
                                    .foregroundStyle(TF.settingsText)
                                    .lineSpacing(2)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius)
                                    .fill(TF.settingsCardAlt)
                            )
                        }
                    }
                }
                .settingsThinScrollIndicators()
            }
        }
        .padding(18)
        .frame(width: 420, height: 360, alignment: .topLeading)
        .background(TF.settingsCanvas)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension ExtractionOutputKind {
    var settingsDisplayTitle: String {
        switch self {
        case .assetCandidates:
            return L("候选资产", "Asset candidates")
        case .todoList:
            return L("待办清单", "Todo list")
        case .dailyReport:
            return L("工作日报", "Daily report")
        case .summary:
            return L("总结", "Summary")
        case .custom:
            return L("自定义", "Custom")
        }
    }

    var settingsAccentColor: Color {
        switch self {
        case .assetCandidates:
            return TF.settingsAccentGreen
        case .todoList:
            return TF.settingsAccentBlue
        case .dailyReport:
            return TF.settingsAccentAmber
        case .summary:
            return TF.settingsAccentGreen
        case .custom:
            return TF.settingsTextTertiary
        }
    }
}
