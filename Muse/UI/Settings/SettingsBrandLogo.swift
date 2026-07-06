import AppKit
import SwiftUI

struct SettingsBrandLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat
    var lightOpacity: Double = 0.64
    var darkOpacity: Double = 0.70

    private static let logoAspectRatio: CGFloat = 1126.0 / 461.0

    var body: some View {
        Group {
            if let image = Self.logoImage {
                logoImageView(image)
            } else {
                Text("Muse")
                    .font(TF.settingsFontCaption)
                    .tracking(1.6)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private func logoImageView(_ image: NSImage) -> some View {
        let pointHeight = width / Self.logoAspectRatio

        let base = SettingsBrandLogoImage(image: image)
            .frame(width: width, height: pointHeight, alignment: .leading)

        if colorScheme == .dark {
            base
                .colorInvert()
                .opacity(darkOpacity)
        } else {
            base
                .opacity(lightOpacity)
        }
    }

    private static var logoImage: NSImage? {
        if let bundledURL = Bundle.main.url(forResource: "BrandLogo", withExtension: "png"),
           let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let sourceResourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BrandLogo.png")
        return NSImage(contentsOf: sourceResourceURL)
    }
}

private struct SettingsBrandLogoImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageAlignment = .alignLeft
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.minificationFilter = .trilinear
        imageView.layer?.magnificationFilter = .linear
        imageView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.image = image
        imageView.layer?.contentsScale = imageView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }
}
