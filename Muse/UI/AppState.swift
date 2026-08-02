import AppKit
import SwiftUI

// MARK: - Floating Bar Phase

enum FloatingBarPhase: Equatable {
    case hidden
    case preparing
    case recording
    case processing
    case done
    case copyFallback
    case error
}

/// canonical 出口请求的最终归属。`stale` 表示请求发出后 HUD 已换代，
/// 调用方必须忽略迟到 ACK，不能据此取消当前或下一条会话。
enum VoicePolishCanonicalExitResult: Equatable {
    case accepted
    case rejected
    case stale

    /// ESC 只有在当前 HUD 确认未接管 canonical 出口时，才继续原有取消语义。
    var shouldAbortSessionAfterEscape: Bool {
        self == .rejected
    }
}

// MARK: - Transcription Segment

struct TranscriptionSegment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isConfirmed: Bool

    init(text: String, isConfirmed: Bool) {
        self.id = UUID()
        self.text = text
        self.isConfirmed = isConfirmed
    }
}


// MARK: - Audio Level (isolated from @Observable to avoid high-frequency view invalidation)

@MainActor
final class AudioLevelMeter {
    /// Current mic level. Updated at audio-callback rate but NOT observed by SwiftUI,
    /// so it won't trigger view-tree diffs. Views read it inside Canvas/TimelineView draws.
    var current: Float = 0.0
}

// MARK: - App State

@Observable
@MainActor
final class AppState {

    // MARK: Floating Bar

    var barPhase: FloatingBarPhase = .hidden
    var segments: [TranscriptionSegment] = []
    var currentMode: ProcessingMode
    @ObservationIgnored let audioLevel = AudioLevelMeter()
    var recordingStartDate: Date?
    /// preparing 起点：观测「HUD 转很久才能输入」的实际耗时
    var preparingStartDate: Date?
    var availableModes: [ProcessingMode]
    var feedbackMessage: String = L("已完成", "Done")
    var processingFinishTime: Date?
    var copyFallbackWasCopied = false
    var preserveProcessingWidthForCopyFallback = false
    var voicePolishStage: VoicePolishStage?
    var canUseVoicePolishCanonicalText = false
    var isRequestingVoicePolishCanonicalText = false
    var voicePolishCanonicalExitMessage: String?
    var isQwen3OnlyMode: Bool {
        SenseVoiceServerManager.currentPort == nil && SenseVoiceServerManager.currentQwen3Port != nil
    }

    // MARK: Panel Control (not observed by SwiftUI)

    @ObservationIgnored var onShowPanel: (() -> Void)?
    @ObservationIgnored var onHidePanel: (() -> Void)?
    @ObservationIgnored var onCopyFallbackVisibilityChange: ((Bool) -> Void)?
    @ObservationIgnored var onUseVoicePolishCanonicalText: (() async -> Bool)?
    @ObservationIgnored private let voicePolishCanonicalExitDelay: Duration
    @ObservationIgnored private var voicePolishCanonicalExitGeneration = 0
    /// canonical 已接受或 pipeline 已提交结果后，在 finalized/completed 之前屏蔽重复 ESC。
    @ObservationIgnored private var hasCommittedVoicePolishTerminalResult = false

    // MARK: Update Check

    var availableUpdates: [UpdateInfo] = []
    var hasUnseenUpdate: Bool = false

    // MARK: Setup

    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.hasCompletedSetup) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.hasCompletedSetup) }
    }

    init(
        initialModes: [ProcessingMode]? = nil,
        voicePolishCanonicalExitDelay: Duration = .milliseconds(1_200)
    ) {
        // 测试必须注入内存模式，避免读取或隔离真实用户的 modes.json。
        let modes = initialModes ?? ModeStorage().load()
        availableModes = modes
        currentMode = modes.first(where: { $0.id == ProcessingMode.smartDirectId })
            ?? modes.first
            ?? .direct
        self.voicePolishCanonicalExitDelay = voicePolishCanonicalExitDelay
    }

    // MARK: Actions

    func startRecording() {
        segments = []
        audioLevel.current = 0
        recordingStartDate = nil
        feedbackMessage = L("已完成", "Done")
        copyFallbackWasCopied = false
        preserveProcessingWidthForCopyFallback = false
        resetVoicePolishProcessingState()
        onCopyFallbackVisibilityChange?(false)
        barPhase = .preparing
        preparingStartDate = Date()
        onShowPanel?()
    }

    func markRecordingReady() {
        guard barPhase == .preparing else { return }
        // 观测：偶发「HUD 红色图标转很久才能输入」——记录 preparing 实际耗时便于复现定位
        if let preparingStartDate {
            let elapsedMs = Int(Date().timeIntervalSince(preparingStartDate) * 1000)
            if elapsedMs > 800 {
                DebugFileLogger.log("preparing→recording 偏慢: \(elapsedMs)ms")
            }
        }
        preparingStartDate = nil
        audioLevel.current = 0
        recordingStartDate = Date()
        barPhase = .recording
    }

    func stopRecording() {
        switch barPhase {
        case .preparing:
            cancel()
        case .recording:
            processingFinishTime = nil
            resetVoicePolishProcessingState()
            // 2026-07 修回归：AX 焦点查询对微信等无响应进程可阻塞主线程数百 ms（AX 超时上限秒级），
            // 曾导致停止录音瞬间 HUD 冻结（文字不显示/卡顿）。改后台计算，先按 false 走流程
            preserveProcessingWidthForCopyFallback = false
            withAnimation(TF.hudMorph) {
                barPhase = .processing
            }
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if TextInjectionEngine.canReadFocusedEditableElement,
               !TextInjectionEngine.isAXOpaqueApp(frontmostBundleID) {
                Task.detached(priority: .userInitiated) { [weak self] in
                    let needsReserve = !TextInjectionEngine.frontmostApplicationHasFocusedEditableElement()
                    await MainActor.run { [weak self] in
                        guard let self, self.barPhase == .processing else { return }
                        self.preserveProcessingWidthForCopyFallback = needsReserve
                    }
                }
            }
        default:
            break
        }
    }

    /// 流式上传中断（REPAIR_PLAN B7a）：录音继续、文本不丢（停止后批量兜底），
    /// 在实时字幕区追加一条未确认段提示用户继续说话即可
    func showStreamingInterrupted() {
        guard barPhase == .recording else { return }
        let hint = L("（网络中断，松手后自动完整重识别）",
                     "(Connection lost — full re-recognition after you stop)")
        guard segments.last?.text != hint else { return }
        segments.append(TranscriptionSegment(text: hint, isConfirmed: false))
    }

    func setLiveTranscript(_ transcript: RecognitionTranscript) {
        if transcript.isFinal,
           !transcript.authoritativeText.isEmpty,
           transcript.authoritativeText != transcript.composedText {
            segments = [TranscriptionSegment(text: transcript.authoritativeText, isConfirmed: true)]
            return
        }

        segments = transcript.confirmedSegments.map {
            TranscriptionSegment(text: $0, isConfirmed: true)
        }
        if !transcript.partialText.isEmpty {
            segments.append(TranscriptionSegment(text: transcript.partialText, isConfirmed: false))
        }
    }

    func showProcessingResult(_ result: String) {
        if result.isEmpty {
            cancel()
            return
        }
        copyFallbackWasCopied = false
        segments = [TranscriptionSegment(text: result, isConfirmed: true)]
        if barPhase == .processing, currentMode.kind == .voicePolish {
            hasCommittedVoicePolishTerminalResult = true
        }
        // processingResult 表示 Session 已提交最终输出，canonical 出口不再可用。
        // 必须在 finalized 之前关闭，避免注入阶段仍显示一个后台必然拒绝的按钮。
        resetVoicePolishProcessingState(preserveTerminalResult: true)
    }

    func showVoicePolishStage(_ stage: VoicePolishStage) {
        guard barPhase == .processing, currentMode.kind == .voicePolish else { return }
        let shouldScheduleCanonicalExit = voicePolishStage == nil
            && !canUseVoicePolishCanonicalText
        voicePolishStage = stage
        guard shouldScheduleCanonicalExit else { return }

        voicePolishCanonicalExitGeneration &+= 1
        let generation = voicePolishCanonicalExitGeneration
        if voicePolishCanonicalExitDelay <= .zero {
            canUseVoicePolishCanonicalText = true
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.voicePolishCanonicalExitDelay)
            guard self.voicePolishCanonicalExitGeneration == generation,
                  self.barPhase == .processing,
                  self.currentMode.kind == .voicePolish,
                  self.voicePolishStage != nil else { return }
            self.canUseVoicePolishCanonicalText = true
        }
    }

    func useVoicePolishCanonicalText() {
        Task { @MainActor [weak self] in
            _ = await self?.useVoicePolishCanonicalTextIfAvailable(
                restoreOnFailure: true
            )
        }
    }

    /// 鼠标、VoiceOver 与 ESC 最终都等待 RecognitionSession 的明确确认。
    /// AppState 的可用态只负责防重复点击，不能自行宣告 canonical 已被接受。
    @discardableResult
    func useVoicePolishCanonicalTextIfAvailable(
        restoreOnFailure: Bool
    ) async -> VoicePolishCanonicalExitResult {
        if isRequestingVoicePolishCanonicalText || hasCommittedVoicePolishTerminalResult {
            // 请求在途或已收到成功 ACK 时，后续 ESC 都属于重复事件；不得把
            // `canUse=false` 误解成当前会话明确拒绝并继续 abort。
            return .stale
        }
        guard barPhase == .processing,
              currentMode.kind == .voicePolish,
              canUseVoicePolishCanonicalText else { return .rejected }
        voicePolishCanonicalExitGeneration &+= 1
        let generation = voicePolishCanonicalExitGeneration
        canUseVoicePolishCanonicalText = false
        isRequestingVoicePolishCanonicalText = true
        voicePolishCanonicalExitMessage = L("正在切换…", "Switching…")

        let accepted = await onUseVoicePolishCanonicalText?() ?? false
        guard voicePolishCanonicalExitGeneration == generation,
              barPhase == .processing,
              currentMode.kind == .voicePolish else {
            // Session 结果已经提交或 HUD 已进入其他阶段时，ACK 已失去归属。
            // 无论后台返回 true/false，都不能复活按钮或触发 ESC abort。
            return .stale
        }

        isRequestingVoicePolishCanonicalText = false
        if accepted {
            hasCommittedVoicePolishTerminalResult = true
            voicePolishCanonicalExitMessage = L(
                "正在使用纠正文本…",
                "Using corrected transcript…"
            )
            return .accepted
        }

        if restoreOnFailure, voicePolishStage != nil {
            canUseVoicePolishCanonicalText = true
            voicePolishCanonicalExitMessage = L(
                "切换失败，点击重试",
                "Switch failed — retry"
            )
        } else {
            voicePolishCanonicalExitMessage = nil
        }
        return .rejected
    }

    func finalize(text: String, outcome: InjectionOutcome) {
        guard !text.isEmpty else {
            cancel()
            return
        }
        segments = [TranscriptionSegment(text: text, isConfirmed: true)]
        resetVoicePolishProcessingState()
        if case .noFocusedInput(let copiedToClipboard) = outcome {
            showCopyFallback(message: outcome.completionMessage, copiedToClipboard: copiedToClipboard)
            return
        }
        showDone(message: outcome.completionMessage)
    }

    func showError(_ message: String) {
        feedbackMessage = message
        resetVoicePolishProcessingState()
        audioLevel.current = 0
        recordingStartDate = nil
        onCopyFallbackVisibilityChange?(false)
        barPhase = .error
        onShowPanel?()
        scheduleAutoHide(for: .error, delay: .seconds(1.8))
    }

    func cancel() {
        barPhase = .hidden
        segments = []
        audioLevel.current = 0
        copyFallbackWasCopied = false
        preserveProcessingWidthForCopyFallback = false
        resetVoicePolishProcessingState()
        onCopyFallbackVisibilityChange?(false)
        onHidePanel?()
    }

    func showCancelled() {
        feedbackMessage = L("已取消", "Cancelled")
        resetVoicePolishProcessingState()
        audioLevel.current = 0
        recordingStartDate = nil
        onCopyFallbackVisibilityChange?(false)
        barPhase = .done
        scheduleAutoHide(for: .done, delay: .seconds(0.8))
    }

    func copyFallbackToClipboard() {
        let text = transcriptionText
        guard !text.isEmpty else {
            dismissCopyFallback()
            return
        }

        ClipboardLeaseCoordinator.shared.writeTextPermanently(text)
        copyFallbackWasCopied = true
        feedbackMessage = L("已复制", "Copied")
        scheduleAutoHide(for: .copyFallback, delay: .seconds(0.9))
    }

    func dismissCopyFallback() {
        cancel()
    }

    // MARK: Computed

    var transcriptionText: String {
        segments.map(\.text).joined()
    }

    func reconcileCurrentMode(for provider: ASRProvider) {
        let resolved = ASRProviderRegistry.resolvedMode(for: currentMode, provider: provider)
        guard resolved.id != currentMode.id else { return }
        currentMode = availableModes.first(where: { $0.id == resolved.id }) ?? resolved
    }

    // MARK: Private

    private var hideGeneration = 0

    private func resetVoicePolishProcessingState(preserveTerminalResult: Bool = false) {
        voicePolishCanonicalExitGeneration &+= 1
        voicePolishStage = nil
        canUseVoicePolishCanonicalText = false
        isRequestingVoicePolishCanonicalText = false
        if !preserveTerminalResult {
            hasCommittedVoicePolishTerminalResult = false
        }
        voicePolishCanonicalExitMessage = nil
    }

    private func showDone(message: String = L("已完成", "Done")) {
        feedbackMessage = message
        resetVoicePolishProcessingState()
        copyFallbackWasCopied = false
        preserveProcessingWidthForCopyFallback = false
        onCopyFallbackVisibilityChange?(false)
        barPhase = .done
        scheduleAutoHide(for: .done, delay: .seconds(0.8))
    }

    private func showCopyFallback(message: String, copiedToClipboard: Bool) {
        feedbackMessage = message
        copyFallbackWasCopied = copiedToClipboard
        audioLevel.current = 0
        recordingStartDate = nil
        withAnimation(TF.hudMorph) {
            barPhase = .copyFallback
        }
        onCopyFallbackVisibilityChange?(true)
        onShowPanel?()
    }

    private func scheduleAutoHide(for phase: FloatingBarPhase, delay: Duration) {
        hideGeneration += 1
        let myGeneration = hideGeneration
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard barPhase == phase, hideGeneration == myGeneration else { return }
            barPhase = .hidden
            preserveProcessingWidthForCopyFallback = false
            if phase == .copyFallback {
                copyFallbackWasCopied = false
                onCopyFallbackVisibilityChange?(false)
            }
            onHidePanel?()
        }
    }
}

// MARK: - FloatingBarState Conformance

extension AppState: FloatingBarState {}

extension Notification.Name {
    static let modesDidChange = Notification.Name("MuseModesDidChange")
    static let asrProviderDidChange = Notification.Name("MuseASRProviderDidChange")
    static let hotkeyRecordingDidStart = Notification.Name("MuseHotkeyRecordingDidStart")
    static let hotkeyRecordingDidEnd = Notification.Name("MuseHotkeyRecordingDidEnd")
    static let navigateToMode = Notification.Name("MuseNavigateToMode")
    static let navigateToTab = Notification.Name("MuseNavigateToTab")
    static let selectMode = Notification.Name("MuseSelectMode")
}
