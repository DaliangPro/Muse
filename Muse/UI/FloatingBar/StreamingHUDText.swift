import AppKit
import SwiftUI

/// 始终保留同一行文字：外壳展开时渐显，满宽后平滑移走左侧旧内容。
struct StreamingHUDText: View {
    let text: String
    let color: Color
    let leadingFadeWidth: CGFloat
    var trailingFadeWidth: CGFloat = 14

    var body: some View {
        // 与 HUD 字号一致；在正文变化时计算，不在逐帧波形里测量。
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width)
        StreamingHUDTextPresentation(
            text: text, color: color, textWidth: textWidth,
            leadingFadeWidth: leadingFadeWidth, trailingFadeWidth: trailingFadeWidth
        )
        .allowsHitTesting(false)
    }
}

private struct StreamingHUDTextPresentation: View {
    @Environment(\.hudRecordingLayout) private var layout
    let text: String
    let color: Color
    let textWidth: CGFloat
    let leadingFadeWidth: CGFloat
    let trailingFadeWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = layout?.textViewportWidth ?? max(0, geometry.size.width)
            let presentedWidth = layout?.presentedTextWidth ?? textWidth
            // 尾端预留完整的渐隐区，停下后最后一个字能完全进入清晰区域。
            let tailInset = min(trailingFadeWidth, viewportWidth / 2)
            let offset = layout?.textOffset ?? min(0, viewportWidth - tailInset - presentedWidth)
            #if HUD_PERFORMANCE_PROBE
            let _ = HUDPerformanceProbe.recordText(width: textWidth, presentedWidth: presentedWidth,
                                                   viewport: viewportWidth, offset: offset)
            #endif

            Text(text)
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: textWidth, height: geometry.size.height, alignment: .leading)
                .offset(x: offset)
                .frame(width: viewportWidth, height: geometry.size.height, alignment: .leading)
                .clipped()
                .mask {
                    HUDTextEdgeMask(leadingFadeWidth: leadingFadeWidth, trailingFadeWidth: trailingFadeWidth,
                                    hasLeadingOverflow: offset < -0.5)
                }
        }
        // 位移已由 presentedWidth 连续插值；字形和遮罩不再各自叠加动画。
        .transaction { $0.animation = nil }
    }
}

struct HUDTextEdgeMask: View {
    let leadingFadeWidth: CGFloat
    let trailingFadeWidth: CGFloat
    let hasLeadingOverflow: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LinearGradient(colors: [hasLeadingOverflow ? .clear : .white, .white],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(leadingFadeWidth, geometry.size.width / 2))
                Rectangle()
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(trailingFadeWidth, geometry.size.width / 2))
            }
        }
    }
}
