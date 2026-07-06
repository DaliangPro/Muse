import SwiftUI

struct AssetExtractionProgressBanner: View {
    let stage: AssetExtractionProgressStage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("提炼中", "Extracting"))
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(TF.settingsStroke.opacity(0.45))
                    Capsule()
                        .fill(TF.settingsAccentGreen)
                        .frame(width: max(proxy.size.width * progressFraction, 10))
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: AssetLibraryStyle.innerPanelCornerRadius)
                .fill(AssetLibraryStyle.restingWhite)
        )
    }

    private var progressFraction: CGFloat {
        let total = max(AssetExtractionProgressStage.allCases.count, 1)
        return min(max(CGFloat(stage.displayIndex) / CGFloat(total), 0), 1)
    }
}
