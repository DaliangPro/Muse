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

    private func restorePasteboardItems(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
