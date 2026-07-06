import SwiftUI

struct AssetLibraryRuleStrategyCard: View {
    @Binding var ruleConfig: AssetExtractionRuleConfig
    @State private var pendingAudience = ""
    @State private var isAddingAudience = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controlsRow
            audienceRow
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private extension AssetLibraryRuleStrategyCard {
    var controlsRow: some View {
        HStack(alignment: .center, spacing: 24) {
            inlineControl(title: L("过滤强度", "Filter")) {
                filterControl
            }

            inlineControl(title: L("保留等级", "Grade")) {
                saveThresholdControl
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var filterControl: some View {
        SettingsSwitchGroup(
            width: 154,
            height: AssetStrategyControlLayout.controlHeight,
            spacing: 2,
            padding: 2
        ) {
            ForEach(AssetLowValueFilter.allCases, id: \.self) { value in
                SettingsSwitchOption(
                    title: filterTitle(for: value),
                    isSelected: ruleConfig.lowValueFilter == value
                ) {
                    ruleConfig.lowValueFilter = value
                }
            }
        }
    }

    var saveThresholdControl: some View {
        SettingsSwitchGroup(
            width: 112,
            height: AssetStrategyControlLayout.controlHeight,
            spacing: 2,
            padding: 2
        ) {
            ForEach(AssetSaveThreshold.allCases, id: \.self) { value in
                SettingsSwitchOption(
                    title: saveThresholdTitle(for: value),
                    isSelected: ruleConfig.saveThreshold == value
                ) {
                    ruleConfig.saveThreshold = value
                }
            }
        }
    }

    func inlineControl<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            strategyLabel(title)

            content()
        }
    }

    var audienceRow: some View {
        strategyRow(title: L("目标读者", "Audience")) {
            AudienceTagFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(AudienceFocusOption.presets) { option in
                    AudienceTagButton(
                        title: option.title,
                        isSelected: selectedAudienceValues.contains(option.value)
                    ) {
                        toggleAudience(option.value)
                    }
                }

                ForEach(customAudienceValues, id: \.self) { value in
                    AudienceTagButton(title: value, isSelected: true) {
                        toggleAudience(value)
                    }
                }

                AudienceAddTagControl(text: $pendingAudience, isEditing: $isAddingAudience) {
                    commitPendingAudience()
                }
            }
        }
    }

    @ViewBuilder
    func strategyLabel(_ title: String) -> some View {
        Text(title)
            .font(TF.settingsFontMetadata)
            .foregroundStyle(TF.settingsTextTertiary)
            .lineLimit(1)
            .frame(
                width: AssetStrategyControlLayout.labelWidth,
                height: AssetStrategyControlLayout.controlHeight,
                alignment: .center
            )
    }

    var selectedAudienceValues: [String] {
        AudienceFocusOption.split(ruleConfig.audienceFocus)
    }

    var customAudienceValues: [String] {
        selectedAudienceValues.filter { value in
            !AudienceFocusOption.presets.contains { $0.value == value }
        }
    }

    func strategyRow<Content: View>(
        title: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 10) {
            strategyLabel(title)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func filterTitle(for value: AssetLowValueFilter) -> String {
        switch value {
        case .light:
            return L("轻", "Light")
        case .standard:
            return L("标准", "Standard")
        case .strong:
            return L("严格", "Strict")
        }
    }

    func saveThresholdTitle(for value: AssetSaveThreshold) -> String {
        switch value {
        case .aOnly:
            return L("A 级", "A")
        case .aAndB:
            return L("A+B", "A+B")
        }
    }

    func toggleAudience(_ value: String) {
        var values = selectedAudienceValues
        if values.contains(value) {
            values.removeAll { $0 == value }
        } else {
            values.append(value)
        }
        ruleConfig.audienceFocus = AudienceFocusOption.join(values)
    }

    func commitPendingAudience() {
        let values = AudienceFocusOption.split(pendingAudience)
        guard !values.isEmpty else { return }

        ruleConfig.audienceFocus = AudienceFocusOption.join(selectedAudienceValues + values)
        pendingAudience = ""
        isAddingAudience = false
    }
}

private struct AudienceTagButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(TF.settingsFontControl)
                .foregroundStyle(isSelected ? TF.settingsPrimaryActionText : TF.settingsTextTertiary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 9)
                .frame(
                    minWidth: 42,
                    minHeight: AssetStrategyControlLayout.tagHeight,
                    maxHeight: AssetStrategyControlLayout.tagHeight,
                    alignment: .center
                )
                .background {
                    RoundedRectangle(cornerRadius: AssetStrategyControlLayout.tagCornerRadius, style: .continuous)
                        .fill(background)
                }
                .contentShape(RoundedRectangle(cornerRadius: AssetStrategyControlLayout.tagCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }

    private var background: Color {
        if isSelected {
            return TF.settingsPrimaryActionFill
        }
        return isHovered ? TF.settingsGhostActionFill.opacity(0.68) : TF.settingsGhostActionFill.opacity(0.42)
    }
}

private struct AudienceAddTagControl: View {
    @Binding var text: String
    @Binding var isEditing: Bool
    let onCommit: () -> Void

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 4) {
                    TextField(
                        "",
                        text: $text,
                        prompt: Text(L("标签", "Tag")).foregroundStyle(TF.settingsTextTertiary)
                    )
                    .textFieldStyle(.plain)
                    .font(TF.settingsFontControl)
                    .foregroundStyle(TF.settingsText)
                    .frame(width: 62)
                    .onSubmit(onCommit)

                    Button(action: onCommit) {
                        Image(systemName: "plus")
                            .font(TF.settingsFontIconSmall)
                            .foregroundStyle(canCommit ? TF.settingsPrimaryActionText : TF.settingsTextTertiary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(width: 94, height: AssetStrategyControlLayout.tagHeight)
            } else {
                Button {
                    isEditing = true
                } label: {
                    HStack(spacing: 5) {
                        Text(L("新增", "Add"))
                            .font(TF.settingsFontControl)
                            .multilineTextAlignment(.center)
                        Image(systemName: "plus")
                            .font(TF.settingsFontIconSmall)
                    }
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 9)
                    .frame(
                        minWidth: 58,
                        minHeight: AssetStrategyControlLayout.tagHeight,
                        maxHeight: AssetStrategyControlLayout.tagHeight,
                        alignment: .center
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: AssetStrategyControlLayout.tagCornerRadius, style: .continuous)
                .fill(TF.settingsGhostActionFill.opacity(0.42))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var canCommit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct AudienceTagFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangeSubviews(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangeSubviews(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews).rows
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (rows: [AudienceTagFlowRow], size: CGSize) {
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let maxWidth = max(proposedWidth, 0)
        var rows: [AudienceTagFlowRow] = []
        var current = AudienceTagFlowRow()

        for index in subviews.indices {
            let measuredSize = subviews[index].sizeThatFits(.unspecified)
            let itemSize = CGSize(width: min(measuredSize.width, maxWidth), height: measuredSize.height)
            let nextWidth = current.items.isEmpty
                ? itemSize.width
                : current.width + horizontalSpacing + itemSize.width

            if !current.items.isEmpty, nextWidth > maxWidth {
                rows.append(current)
                current = AudienceTagFlowRow()
            }

            current.append(index: index, size: itemSize, spacing: horizontalSpacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height
        } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing

        return (
            rows,
            CGSize(
                width: proposal.width ?? contentWidth,
                height: contentHeight
            )
        )
    }
}

private struct AudienceTagFlowRow {
    struct Item {
        let index: Int
        let size: CGSize
    }

    var items: [Item] = []
    var width: CGFloat = 0
    var height: CGFloat = 0

    mutating func append(index: Int, size: CGSize, spacing: CGFloat) {
        if !items.isEmpty {
            width += spacing
        }
        items.append(Item(index: index, size: size))
        width += size.width
        height = max(height, size.height)
    }
}

private enum AssetStrategyControlLayout {
    static let labelWidth: CGFloat = 52
    static let controlHeight: CGFloat = 24
    static let tagHeight: CGFloat = 24
    static let tagCornerRadius: CGFloat = 7
}

private struct AudienceFocusOption: Identifiable, Hashable {
    let value: String
    let zhTitle: String
    let enTitle: String

    var id: String { value }
    var title: String { L(zhTitle, enTitle) }

    static let presets: [AudienceFocusOption] = [
        AudienceFocusOption(value: "内容创作者", zhTitle: "内容创作者", enTitle: "Creators"),
        AudienceFocusOption(value: "个人IP", zhTitle: "个人IP", enTitle: "个人IP"),
        AudienceFocusOption(value: "自媒体", zhTitle: "自媒体", enTitle: "Media"),
        AudienceFocusOption(value: "知识博主", zhTitle: "知识博主", enTitle: "Educators"),
        AudienceFocusOption(value: "创业者", zhTitle: "创业者", enTitle: "Founders"),
        AudienceFocusOption(value: "产品经理", zhTitle: "产品经理", enTitle: "PMs"),
    ]

    static func split(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: "、,，/／"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) {
                    result.append(value)
                }
            }
    }

    static func join(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) {
                    result.append(value)
                }
            }
            .joined(separator: "、")
    }
}
