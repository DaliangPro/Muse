import AppKit
import SwiftUI

/// 使用同一个文字视图承接流式更新，当前视窗容不下时从左侧裁去旧内容。
struct StreamingHUDText: View {
    let text: String
    let color: Color
    let leadingFadeWidth: CGFloat

    var body: some View {
        // 与 HUD 字号一致；在正文变化时计算，不在逐帧波形里测量。
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width)

        GeometryReader { geometry in
            let viewportWidth = max(0, geometry.size.width)
            let overflow = max(0, textWidth - viewportWidth)

            Text(text)
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: textWidth, height: geometry.size.height, alignment: .leading)
                .offset(x: -overflow)
                // 新字立即跟随当前视窗定位，避免再叠加一次位移或透明度动画。
                .transaction { $0.animation = nil }
                .frame(width: viewportWidth, height: geometry.size.height, alignment: .leading)
                .clipped()
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [overflow > 0 ? .clear : .white, .white],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: min(leadingFadeWidth, viewportWidth))
                        Rectangle()
                    }
                    .transaction { $0.animation = nil }
                }
        }
        .allowsHitTesting(false)
    }
}
