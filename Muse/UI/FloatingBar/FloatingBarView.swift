import AppKit
import SwiftUI

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var feedbackMessage: String { get }
    var processingFinishTime: Date? { get }
    var transcriptionText: String { get }
    var recordingStartDate: Date? { get }
    var copyFallbackWasCopied: Bool { get }
    var preserveProcessingWidthForCopyFallback: Bool { get }
    /// True when recording without SenseVoice streaming (Qwen3-only).
    var isQwen3OnlyMode: Bool { get }
    func copyFallbackToClipboard()
}

/// Dark-themed floating transcription bar with smooth morphing between states.
///
/// Design: single capsule container that animates width + content transitions.
/// - Recording: audio-reactive dot + live text + timer, breathing border
/// - Processing: rotating orb with breathing glow + "AI" badge
/// - Done: full progress bar + centered text
struct FloatingBarView<S: FloatingBarState>: View {

    let state: S

    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = TF.barHeight
    @State private var processingStartDate: Date?
    @State private var doneStartDate: Date?

    private var recordingLeadingInset: CGFloat { 3.0 }
    private var recordingTrailingInset: CGFloat { 14.0 }
    private var recordingIconWidth: CGFloat { 40.0 }
    private var recordingIconTextGap: CGFloat {
        AppLaunchDebug.hudDemoSpacingTight ? 3.0 : 4.0
    }
    private var recordingTextTailPadding: CGFloat { 8.0 }
    private var recordingTrimFadeWidth: CGFloat { 4.0 }
    private var capsuleHeight: CGFloat {
        state.barPhase == .copyFallback ? TF.barFallbackHeight : TF.barHeight
    }
    private var capsuleCornerRadius: CGFloat {
        state.barPhase == .copyFallback ? 20 : TF.barHeight / 2
    }
    private var recordingWidthReserve: CGFloat {
        recordingLeadingInset + recordingIconWidth + recordingIconTextGap + recordingTrailingInset + recordingTextTailPadding
    }
    private var isRecordingInitialCircleState: Bool {
        state.segments.isEmpty && !state.isQwen3OnlyMode
    }
    private var isRecordingLabelOnlyState: Bool {
        state.segments.isEmpty && state.isQwen3OnlyMode
    }
    private var usesSuccessCheckmarkDoneContent: Bool {
        state.feedbackMessage == L("已完成", "Done")
    }
    private var shouldTrimRecordingText: Bool {
        recordingPeakWidth >= TF.barWidth
    }

    private var capsuleWidth: CGFloat {
        switch state.barPhase {
        case .preparing:
            return TF.barHeight
        case .recording:
            if state.segments.isEmpty {
                return state.isQwen3OnlyMode ? 124 : TF.barHeight
            }
            return recordingPeakWidth
        case .processing:
            return processingWidth()
        case .done:
            return feedbackWidth(for: state.feedbackMessage)
        case .copyFallback:
            return copyFallbackWidth()
        case .error:
            return feedbackWidth(for: state.feedbackMessage)
        case .hidden:
            return TF.barHeight
        }
    }

    var body: some View {
        Group {
            if state.barPhase != .hidden {
                capsuleBar
                    .padding(.bottom, TF.barOuterInset)
                    .transition(.asymmetric(
                        insertion: .offset(y: 8).combined(with: .scale(scale: 0.985)).combined(with: .opacity),
                        removal: .offset(y: -4).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(TF.hudVisibility, value: state.barPhase != .hidden)
        .onChange(of: state.barPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: state.transcriptionText) { _, newText in
            guard state.barPhase == .recording else { return }
            let textWidth = measureText(newText)
            let needed = recordingTargetWidth(for: textWidth)
            if needed > recordingPeakWidth {
                // Widen smoothly while streaming so the shell doesn't "jump" on every ASR update.
                withAnimation(TF.hudWidthFlow) {
                    recordingPeakWidth = needed
                }
            } else if recordingPeakWidth - needed > 30 {
                // Large correction (hotword etc.): allow shrink
                withAnimation(TF.hudWidthFlow) {
                    recordingPeakWidth = needed
                }
            }
        }
    }

    // MARK: - Capsule Container

    private var capsuleBar: some View {
        Group {
            if #available(macOS 26.0, *) {
                liquidCapsuleCore
            } else {
                legacyCapsuleCore
            }
        }
        .frame(width: capsuleWidth, height: capsuleHeight)
        .shadow(color: capsuleShadowColor, radius: capsuleShadowRadius, x: 0, y: capsuleShadowYOffset)
        .animation(TF.hudMorph, value: state.barPhase)
        .animation(TF.hudWidthFlow, value: capsuleWidth)
        .animation(TF.hudMorph, value: capsuleHeight)
    }

    private var capsuleShadowColor: Color {
        if #available(macOS 26.0, *), nativeGlassVariant == .clearCore || nativeGlassVariant == .minimalRegular {
            return Color.black.opacity(0.08)
        }
        return Color.black.opacity(0.18)
    }

    private var capsuleShadowRadius: CGFloat {
        if #available(macOS 26.0, *), nativeGlassVariant == .clearCore || nativeGlassVariant == .minimalRegular {
            return 10
        }
        return 7
    }

    private var capsuleShadowYOffset: CGFloat {
        if #available(macOS 26.0, *), nativeGlassVariant == .clearCore || nativeGlassVariant == .minimalRegular {
            return 5
        }
        return 4
    }

    private var legacyCapsuleCore: some View {
        ZStack {
            capsuleSurface
            capsuleOverlay

            barContent
                .animation(TF.hudMorph, value: state.barPhase)
                .frame(width: capsuleWidth, height: capsuleHeight)
                .overlay { capsuleBorder }
                .clipShape(RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous))
        }
    }

    @available(macOS 26.0, *)
    private var liquidCapsuleCore: some View {
        return Group {
            if nativeGlassVariant == .minimalRegular {
                CleanGlassCapsule(
                    cornerRadius: capsuleCornerRadius,
                    style: UserDefaults.standard.bool(forKey: "museGlassClearStyle") ? .clear : .regular,
                    tintColor: nil,
                    content: AnyView(
                        barContent
                            .animation(TF.hudMorph, value: state.barPhase)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                )
                .overlay {
                    // 双向边缘（2026-06-24 大梁老师）：白高光在暗背景上勾边、深色边界在亮/纯白背景上勾边，
                    // 互补 → 任何背景下玻璃都有可见轮廓、不会融进白里消失。
                    ZStack {
                        // 深色边界：纯白/亮背景上勾出玻璃形状，不让它融成一片白
                        RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.75)
                        // 白高光 specular rim：暗背景上的亮边 + 立体厚度感
                        RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.55),
                                        Color.white.opacity(0.14),
                                        Color.white.opacity(0.03),
                                        Color.white.opacity(0.22),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.0
                            )
                            .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                }
            } else {
                NativeLiquidGlassCapsule(
                    cornerRadius: capsuleCornerRadius,
                    variant: nativeGlassVariant,
                    style: nativeGlassStyle,
                    tintColor: nativeGlassTintColor,
                    phase: state.barPhase,
                    content: AnyView(
                        barContent
                            .animation(TF.hudMorph, value: state.barPhase)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous))
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous))
            }
        }
    }

    // MARK: - Content by Phase

    @ViewBuilder
    private var barContent: some View {
        switch state.barPhase {
        case .preparing:
            preparingContent
                .transition(.asymmetric(
                    insertion: .offset(y: 4).combined(with: .opacity),
                    removal: .opacity
                ))
        case .recording:
            recordingContent
                .transition(.asymmetric(
                    insertion: .offset(x: 6).combined(with: .opacity),
                    removal: .offset(x: -4).combined(with: .opacity)
                ))
        case .processing:
            processingContent
                .transition(.asymmetric(
                    insertion: .offset(y: 3).combined(with: .opacity),
                    removal: .offset(y: -2).combined(with: .opacity)
                ))
        case .done:
            doneContent
                .transition(.asymmetric(
                    insertion: .offset(y: 2).combined(with: .opacity),
                    removal: .opacity
                ))
        case .copyFallback:
            copyFallbackContent
                .transition(.asymmetric(
                    insertion: .offset(y: 2).combined(with: .opacity),
                    removal: .opacity
                ))
        case .error:
            errorContent
                .transition(.asymmetric(
                    insertion: .offset(y: 2).combined(with: .opacity),
                    removal: .opacity
                ))
        case .hidden:
            EmptyView()
        }
    }

    private var preparingContent: some View {
        HStack(spacing: 0) {
            PreparingDot()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingContent: some View {
        Group {
            if isRecordingInitialCircleState {
                AnimatedRecordingIndicatorCluster(
                    audioLevel: state.audioLevel,
                    recordingStartDate: state.recordingStartDate
                ) {
                    activity, time, flow in
                    recordingInitialCircleContent(activity: activity, time: time, flow: flow)
                }
            } else {
                recordingExpandedContent
            }
        }
    }

    private func recordingInitialCircleContent(activity: CGFloat, time: TimeInterval, flow: CGFloat) -> some View {
        ZStack {
            RecordingGlassInnerGlow(activity: activity, time: time)
                .frame(width: 44, height: 34)

            RecordingDot(time: time, activity: activity, flow: flow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingExpandedContent: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                recordingAnimatedWaveZone

                recordingTextZone
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, recordingTrailingInset)
        }
    }

    private var recordingAnimatedWaveZone: some View {
        AnimatedRecordingIndicatorCluster(
            audioLevel: state.audioLevel,
            recordingStartDate: state.recordingStartDate
        ) { activity, time, flow in
            ZStack(alignment: .leading) {
                RecordingGlassInnerGlow(activity: activity, time: time)
                    .frame(width: 76, height: 34)

                RecordingDot(time: time, activity: activity, flow: flow)
                    .frame(width: TF.barHeight, height: TF.barHeight, alignment: .center)
            }
            .frame(width: recordingIconWidth + recordingLeadingInset, height: TF.barHeight, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recordingTextZone: some View {
        if isRecordingLabelOnlyState {
            Text(L("录音中", "Recording"))
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: barTextColor)
                .padding(.leading, recordingIconTextGap)
                .contentTransition(.opacity)
                .animation(TF.hudTextFlow, value: state.transcriptionText)
        } else if !state.segments.isEmpty {
            if shouldTrimRecordingText {
                Color.clear
                    .overlay(alignment: .trailing) {
                        Text(state.transcriptionText)
                            .font(TF.hudFontTitle)
                            .floatingBarReadableText(color: barTextColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.opacity)
                    }
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: recordingTrimFadeWidth)
                            Rectangle()
                        }
                    }
                    .padding(.leading, recordingIconTextGap)
                    .padding(.trailing, recordingTextTailPadding)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(TF.hudTextFlow, value: state.transcriptionText)
            } else {
                Text(state.transcriptionText)
                    .font(TF.hudFontTitle)
                    .floatingBarReadableText(color: barTextColor)
                    .lineLimit(1)
                    .padding(.leading, recordingIconTextGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .contentTransition(.opacity)
                    .animation(TF.hudTextFlow, value: state.transcriptionText)
            }
        }
    }

    private var processingContent: some View {
        ZStack {
            Text(state.currentMode.processingLabel)
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: barTextColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var doneContent: some View {
        ZStack {
            if usesSuccessCheckmarkDoneContent {
                DoneCheckmarkGlyph()
            } else {
                Text(state.feedbackMessage)
                    .font(TF.hudFontTitle)
                    .floatingBarReadableText(color: barTextColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var errorContent: some View {
        HStack(spacing: 8) {
            ErrorDot()

            Text(state.feedbackMessage)
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: barTextColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }

    private var copyFallbackContent: some View {
        VStack(alignment: .center, spacing: 12) {
            Text(state.transcriptionText)
                .font(TF.hudFontTitle)
                .floatingBarReadableText(color: barTextColor)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(width: copyFallbackTextColumnWidth(), alignment: .topLeading)
                .frame(minHeight: 64, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)

            ZStack {
                Button {
                    state.copyFallbackToClipboard()
                } label: {
                    Text(state.copyFallbackWasCopied ? L("已复制", "Copied") : L("复制", "Copy"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(Color.white.opacity(0.98))
                        .frame(width: 60)
                        .frame(height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(copyFallbackButtonFill)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L("复制识别文本", "Copy recognized text"))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    private var copyFallbackButtonFill: Color {
        state.copyFallbackWasCopied
            ? Color(red: 0.46, green: 0.47, blue: 0.49).opacity(0.88)
            : Color(red: 0.40, green: 0.41, blue: 0.43).opacity(0.88)
    }

    // MARK: - Background & Border

    private var capsuleSurface: some View {
        NotificationBlurView(material: .hudWindow)
            .clipShape(RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous))
    }

    private var capsuleOverlay: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.26, green: 0.27, blue: 0.30).opacity(0.24),
                            Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.54),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Rectangle()
                .fill(Color.black.opacity(0.10))

            RadialGradient(
                colors: [
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.04),
                    .clear,
                ],
                center: UnitPoint(x: 0.18, y: 0.06),
                startRadius: 0,
                endRadius: 72
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.01),
                            .clear,
                            Color.black.opacity(0.14),
                        ],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    )
                )

            if state.barPhase == .recording {
                AudioRipple(meter: state.audioLevel)
                    .opacity(0.12)
                    .transition(.opacity)
            }

            if state.barPhase == .processing || state.barPhase == .done {
                ProcessingProgress(
                    finishTime: state.processingFinishTime,
                    processingStartDate: processingStartDate,
                    doneStartDate: doneStartDate
                )
                .opacity(0.14)
                .transition(.opacity)
            }

            if state.barPhase == .copyFallback {
                LinearGradient(
                    colors: [Color.white.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.62, y: 0.5)
                )
                .transition(.opacity)
            }

            if state.barPhase == .error {
                LinearGradient(
                    colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous))
    }

    private var capsuleBorder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.07),
                            Color.white.opacity(0.015),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )

            RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.black.opacity(0.03),
                            Color.black.opacity(0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )

            RoundedRectangle(cornerRadius: capsuleCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.025),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .scaleEffect(x: 0.99, y: 0.74)
                .offset(y: -7.2)
                .blur(radius: 0.7)
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlassVariant: NativeGlassVariant {
        // A/B 对照开关：defaults write pro.daliang.muse museGlassMinimal -bool true → 极简 .regular 裸玻璃
        UserDefaults.standard.bool(forKey: "museGlassMinimal") ? .minimalRegular : .clearCore
    }

    @available(macOS 26.0, *)
    private var nativeGlassStyle: NSGlassEffectView.Style {
        switch nativeGlassVariant {
        case .clearCore, .mergeEdge:
            return .clear
        case .liquidSweep, .minimalRegular:
            return .regular
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlassTintColor: NSColor {
        let alpha: CGFloat
        switch nativeGlassVariant {
        case .clearCore:
            alpha = 0.072
        case .mergeEdge:
            alpha = 0.065
        case .liquidSweep:
            alpha = 0.09
        case .minimalRegular:
            alpha = 0.0   // 极简版先不上 tint，纯材质对照；要加色再调
        }

        return NSColor(
            calibratedRed: 0.30,
            green: 0.38,
            blue: 0.56,
            alpha: alpha
        )
    }

    private var barTextColor: Color {
        Color.white.opacity(0.98)
    }

    // MARK: - Phase Transitions

    private func handlePhaseChange(_ phase: FloatingBarPhase) {
        switch phase {
        case .preparing:
            recordingPeakWidth = TF.barHeight
            processingStartDate = nil
            doneStartDate = nil
        case .recording:
            recordingPeakWidth = TF.barHeight
        case .processing:
            processingStartDate = Date()
            doneStartDate = nil
        case .done:
            doneStartDate = Date()
        case .copyFallback:
            doneStartDate = nil
        case .error:
            break
        default:
            break
        }
    }

    private func feedbackWidth(for message: String) -> CGFloat {
        measureText(message) + 84.0
    }

    private func processingWidth() -> CGFloat {
        let labelWidth = measureText(state.currentMode.processingLabel) + 84.0
        guard state.preserveProcessingWidthForCopyFallback else { return labelWidth }
        let preservedInputWidth = max(TF.barFallbackMinWidth, min(TF.barFallbackWidth, recordingPeakWidth))
        return max(labelWidth, preservedInputWidth)
    }

    private func copyFallbackWidth() -> CGFloat {
        min(TF.barFallbackWidth, max(TF.barFallbackMinWidth, measureText(state.transcriptionText) + 56.0))
    }

    private func copyFallbackTextColumnWidth() -> CGFloat {
        min(360, max(260, copyFallbackWidth() - 40.0))
    }

    private func recordingTargetWidth(for textWidth: CGFloat) -> CGFloat {
        min(TF.barWidth, max(TF.barHeight, textWidth + recordingWidthReserve))
    }

    /// Measure actual rendered width using the same font as the floating bar text.
    private func measureText(_ string: String) -> CGFloat {
        let font = TF.hudNSFontTitle
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}
