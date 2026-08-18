import AppKit
import XCTest
@testable import Muse

@MainActor
final class AppStateTests: XCTestCase {

    private func withChineseAppLanguage(_ action: () -> Void) {
        let savedLanguage = UserDefaults.standard.string(forKey: DefaultsKeys.language)
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: DefaultsKeys.language)
        defer {
            if let savedLanguage {
                UserDefaults.standard.set(savedLanguage, forKey: DefaultsKeys.language)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.language)
            }
        }
        action()
    }

    func testStartRecordingTransitionsToPreparing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()

        XCTAssertEqual(appState.barPhase, .preparing)
    }

    func testStopRecordingIgnoredWhenNotRecording() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .smartDirect
        appState.cancel()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingCancelsWhenPreparing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.startRecording()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingTransitionsToProcessingWhenRecording() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .smartDirect
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testStopRecordingTransitionsDirectModeToProcessing() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.currentMode = .direct
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖"],
                partialText: "",
                authoritativeText: "我想买咖",
                isFinal: false
            )
        )
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖啡"],
                partialText: "",
                authoritativeText: "我想买咖啡",
                isFinal: false
            )
        )

        XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
        XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
    }

    func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["deep seek"],
                partialText: "",
                authoritativeText: "DeepSeek",
                isFinal: true
            )
        )

        XCTAssertEqual(appState.segments.count, 1)
        XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
        XCTAssertTrue(appState.segments.first?.isConfirmed == true)
    }

    func testFinalizeShowsClipboardFallbackMessage() {
        withChineseAppLanguage {
            let appState = AppState(initialModes: ProcessingMode.defaults)

            appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

            XCTAssertEqual(appState.barPhase, .done)
            XCTAssertEqual(appState.feedbackMessage, "已粘贴到剪贴板")
            XCTAssertEqual(appState.transcriptionText, "测试文本")
        }
    }

    func testFinalizeWithoutFocusedInputShowsCopyFallbackCard() {
        withChineseAppLanguage {
            let appState = AppState(initialModes: ProcessingMode.defaults)

            appState.finalize(text: "测试文本", outcome: .noFocusedInput(copiedToClipboard: false))

            XCTAssertEqual(appState.barPhase, .copyFallback)
            XCTAssertEqual(appState.feedbackMessage, "未找到输入位置")
            XCTAssertFalse(appState.copyFallbackWasCopied)
            XCTAssertEqual(appState.transcriptionText, "测试文本")
        }
    }

    func testCopyFallbackCopiesTextAndMarksCopied() {
        withChineseAppLanguage {
            let snapshot = capturePasteboardItems()
            defer { restorePasteboardItems(snapshot) }
            let appState = AppState(initialModes: ProcessingMode.defaults)
            appState.finalize(text: "测试文本", outcome: .noFocusedInput(copiedToClipboard: false))

            appState.copyFallbackToClipboard()

            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "测试文本")
            XCTAssertTrue(appState.copyFallbackWasCopied)
            XCTAssertEqual(appState.feedbackMessage, "已复制")
        }
    }

    func testShowErrorDisplaysErrorPhaseAndMessage() {
        let appState = AppState(initialModes: ProcessingMode.defaults)

        appState.showError("找不到麦克风")

        XCTAssertEqual(appState.barPhase, .error)
        XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
    }

    func testVoicePolishStageEnablesCanonicalExitAndInvokesItOnce() async {
        let appState = AppState(
            initialModes: ProcessingMode.defaults,
            voicePolishCanonicalExitDelay: .zero
        )
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()
        var invocationCount = 0
        appState.onUseVoicePolishCanonicalText = {
            invocationCount += 1
            return true
        }

        appState.showVoicePolishStage(.analyzing)

        XCTAssertEqual(appState.voicePolishStage, .analyzing)
        XCTAssertTrue(appState.canUseVoicePolishCanonicalText)

        let result = await appState.useVoicePolishCanonicalTextIfAvailable(
            restoreOnFailure: true
        )
        let duplicateResult = await appState.useVoicePolishCanonicalTextIfAvailable(
            restoreOnFailure: true
        )

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(duplicateResult, .stale)
        XCTAssertFalse(duplicateResult.shouldAbortSessionAfterEscape)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertFalse(appState.canUseVoicePolishCanonicalText)
        XCTAssertFalse(appState.isRequestingVoicePolishCanonicalText)
        XCTAssertNotNil(appState.voicePolishCanonicalExitMessage)

        appState.showProcessingResult("已选择的纠正原文")
        let afterCommitResult = await appState.useVoicePolishCanonicalTextIfAvailable(
            restoreOnFailure: false
        )
        XCTAssertEqual(afterCommitResult, .stale)
        XCTAssertFalse(afterCommitResult.shouldAbortSessionAfterEscape)
    }

    func testCanonicalExitRejectionRestoresMouseActionAndShowsRetryState() async {
        let appState = makeCanonicalReadyAppState()
        appState.onUseVoicePolishCanonicalText = { false }

        let result = await appState.useVoicePolishCanonicalTextIfAvailable(
            restoreOnFailure: true
        )

        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(result.shouldAbortSessionAfterEscape)
        XCTAssertTrue(appState.canUseVoicePolishCanonicalText)
        XCTAssertFalse(appState.isRequestingVoicePolishCanonicalText)
        XCTAssertNotNil(appState.voicePolishCanonicalExitMessage)
    }

    func testCommittedProcessingResultInvalidatesPendingCanonicalAckWithoutRestoringButton() async {
        let appState = makeCanonicalReadyAppState()
        let gate = VoicePolishCanonicalAckGate()
        appState.onUseVoicePolishCanonicalText = {
            await gate.waitForResolution()
        }

        let requestTask = Task { @MainActor in
            await appState.useVoicePolishCanonicalTextIfAvailable(
                restoreOnFailure: true
            )
        }
        while !(await gate.hasStarted) {
            await Task.yield()
        }
        XCTAssertTrue(appState.isRequestingVoicePolishCanonicalText)

        // 模拟 pipeline 已提交 polished 结果，但迟到的 session ack 随后才返回 false。
        appState.showProcessingResult("已经提交的润色结果")
        await gate.resolve(false)
        let result = await requestTask.value

        XCTAssertEqual(result, .stale)
        XCTAssertFalse(result.shouldAbortSessionAfterEscape)
        XCTAssertNil(appState.voicePolishStage)
        XCTAssertFalse(appState.canUseVoicePolishCanonicalText)
        XCTAssertFalse(appState.isRequestingVoicePolishCanonicalText)
        XCTAssertNil(appState.voicePolishCanonicalExitMessage)
    }

    func testVoicePolishUnavailableRequiresExplicitRetryOrCanonicalChoice() async {
        let appState = AppState(
            initialModes: ProcessingMode.defaults,
            voicePolishCanonicalExitDelay: .zero
        )
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()

        appState.showVoicePolishUnavailable(.validationFailed)

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertTrue(appState.isVoicePolishUnavailable)
        XCTAssertTrue(appState.canUseVoicePolishCanonicalText)
        XCTAssertTrue(appState.voicePolishUnavailableMessage?.contains("原转写已保留") == true)

        var retryCount = 0
        appState.onRetryVoicePolish = {
            retryCount += 1
            return true
        }
        appState.retryVoicePolish()
        for _ in 0..<20 where retryCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(retryCount, 1)
        XCTAssertFalse(appState.isVoicePolishUnavailable)
        XCTAssertEqual(appState.voicePolishStage, .analyzing)
    }

    func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
        let appState = AppState(initialModes: ProcessingMode.defaults)
        let customMode = ProcessingMode(
            id: UUID(),
            name: "结构化",
            prompt: "Rewrite {text}",
            isBuiltin: false
        )
        appState.availableModes.append(customMode)
        appState.currentMode = customMode

        appState.reconcileCurrentMode(for: .volcano)

        XCTAssertEqual(appState.currentMode.id, customMode.id)
    }

    private func capturePasteboardItems() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.map { item in
            let copiedItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }
            return copiedItem
        } ?? []
    }

    private func makeCanonicalReadyAppState() -> AppState {
        let appState = AppState(
            initialModes: ProcessingMode.defaults,
            voicePolishCanonicalExitDelay: .zero
        )
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.stopRecording()
        appState.showVoicePolishStage(.polishing)
        return appState
    }

    private func restorePasteboardItems(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

private actor VoicePolishCanonicalAckGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var hasStarted = false

    func waitForResolution() async -> Bool {
        await withCheckedContinuation { continuation in
            hasStarted = true
            self.continuation = continuation
        }
    }

    func resolve(_ accepted: Bool) {
        continuation?.resume(returning: accepted)
        continuation = nil
    }
}
