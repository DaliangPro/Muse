import Foundation

enum AssetLibraryTagKind: Int, Hashable {
    case scene
    case audience
    case unknown
}

enum AssetLibraryTagSorting {
    private static let scenePriority = priorityMap([
        "IP定位",
        "观点输出",
        "选题",
        "标题",
        "开头",
        "核心段落",
        "口播稿",
        "短视频",
        "直播",
        "案例",
        "金句",
        "转场",
        "结尾",
    ])

    private static let audiencePriority = priorityMap([
        "内容创作者",
        "个人IP",
        "自媒体",
        "知识博主",
        "创业者",
        "产品经理",
    ])

    static func sortedTags(
        _ tags: [String],
        kind: AssetLibraryTagKind,
        limit: Int? = nil
    ) -> [String] {
        sortedItems(
            tags.enumerated().map { index, tag in
                AssetLibraryTagItem(title: tag, kind: kind, sourceIndex: index)
            },
            limit: limit
        )
        .map(\.title)
    }

    static func sortedCombinedTags(
        scenes: [String],
        audiences: [String],
        limit: Int? = nil
    ) -> [String] {
        let sceneItems = scenes.enumerated().map { index, tag in
            AssetLibraryTagItem(title: tag, kind: .scene, sourceIndex: index)
        }
        let audienceItems = audiences.enumerated().map { index, tag in
            AssetLibraryTagItem(title: tag, kind: .audience, sourceIndex: scenes.count + index)
        }
        return sortedItems(sceneItems + audienceItems, limit: limit).map(\.title)
    }

    private static func sortedItems(
        _ rawItems: [AssetLibraryTagItem],
        limit: Int?
    ) -> [AssetLibraryTagItem] {
        var seen = Set<String>()
        let items = rawItems.compactMap { item -> AssetLibraryTagItem? in
            let title = normalizedDisplayTitle(item.title)
            guard !title.isEmpty else { return nil }

            let key = normalizedKey(title)
            guard !seen.contains(key) else { return nil }
            seen.insert(key)

            return AssetLibraryTagItem(title: title, kind: item.kind, sourceIndex: item.sourceIndex)
        }
        .sorted(by: compare)

        guard let limit else { return items }
        return Array(items.prefix(limit))
    }

    private static func compare(_ lhs: AssetLibraryTagItem, _ rhs: AssetLibraryTagItem) -> Bool {
        let lhsCategory = categoryRank(lhs.kind)
        let rhsCategory = categoryRank(rhs.kind)
        if lhsCategory != rhsCategory {
            return lhsCategory < rhsCategory
        }

        let lhsPriority = priorityRank(lhs)
        let rhsPriority = priorityRank(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        return lhs.sourceIndex < rhs.sourceIndex
    }

    private static func categoryRank(_ kind: AssetLibraryTagKind) -> Int {
        switch kind {
        case .scene:
            return 0
        case .audience:
            return 1
        case .unknown:
            return 2
        }
    }

    private static func priorityRank(_ item: AssetLibraryTagItem) -> Int {
        switch item.kind {
        case .scene:
            return scenePriority[normalizedKey(item.title)] ?? Int.max
        case .audience:
            return audiencePriority[normalizedKey(item.title)] ?? Int.max
        case .unknown:
            return Int.max
        }
    }

    private static func normalizedDisplayTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedKey(_ title: String) -> String {
        normalizedDisplayTitle(title)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static func priorityMap(_ titles: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: titles.enumerated().map { index, title in
            (normalizedKey(title), index)
        })
    }
}

private struct AssetLibraryTagItem {
    let title: String
    let kind: AssetLibraryTagKind
    let sourceIndex: Int
}
