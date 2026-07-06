import Foundation

enum AssetLibraryAssetFilters {
    static func creatorAssets(from assets: [LanguageAsset]) -> [LanguageAsset] {
        assets.filter { LanguageAssetType.creatorCases.contains($0.assetType) }
    }

    static func filteredLibraryAssets(
        from creatorAssets: [LanguageAsset],
        selectedType: LanguageAssetType?,
        query: String
    ) -> [LanguageAsset] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return creatorAssets
            .filter { asset in
                guard let selectedType else { return true }
                return asset.assetType == selectedType
            }
            .filter { asset in
                guard !trimmedQuery.isEmpty else { return true }
                return searchableText(for: asset).localizedCaseInsensitiveContains(trimmedQuery)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func searchableText(for asset: LanguageAsset) -> String {
        [
            asset.assetType.settingsDisplayTitle,
            asset.grade?.rawValue ?? "",
            asset.title ?? "",
            asset.content,
            asset.summary ?? "",
            asset.reason ?? "",
            asset.scenes.joined(separator: " "),
            asset.audiences.joined(separator: " "),
            asset.keywords.joined(separator: " "),
        ].joined(separator: " ")
    }
}
