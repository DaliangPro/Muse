import Foundation

enum AssetLibraryDateFormatters {
    static func displayDateTime(_ date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let calendar = Calendar.current
        let dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: referenceDate)
            ? L("M月d日 HH:mm", "MMM d HH:mm")
            : L("yyyy年M月d日 HH:mm", "yyyy MMM d HH:mm")

        return format(date, dateFormat: dateFormat)
    }

}

private extension AssetLibraryDateFormatters {
    static func format(_ date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current == .zh ? "zh-Hans" : "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
