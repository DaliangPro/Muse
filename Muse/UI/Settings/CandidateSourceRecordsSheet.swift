import SwiftUI

struct CandidateSourceRecordsSheet: View {
    let candidate: LanguageAssetCandidateRecord
    let records: [HistoryRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(candidate.title)
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
