import AppKit
import SwiftUI

@main
struct MuseApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 菜单栏图标：填满的圆角方 + M 镂空（2026-06-23 大梁老师嫌 m.square.fill 自带留白、比其它图标小一圈，
    /// 改自绘：圆角方撑满菜单栏高度、M 用 destinationOut 镂空、isTemplate 自适应明暗）
    static let menuBarIcon: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
            let m = NSAttributedString(
                string: "M",
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: NSColor.black]
            )
            let mSize = m.size()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            m.draw(at: NSPoint(x: rect.midX - mSize.width / 2, y: rect.midY - mSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        } label: {
            // 菜单栏图标：自绘填满圆角方 + M 镂空（m.square.fill 自带留白撑不满，改 NSImage 撑满）
            Image(nsImage: Self.menuBarIcon)
        }

        Window(L("Muse 设置", "Muse Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(
            width: SettingsLayout.windowContentWidth,
            height: SettingsLayout.windowContentHeight
        )
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        Window(L("Muse 设置向导", "Muse Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(width: 700, height: 520)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()
    let appUpdater = AppUpdater()
    private let holdHotkeyStopFallbackDelay: Duration = .milliseconds(120)
    private var floatingBarController: FloatingBarController?
    private let hudDebugPresenter = HUDDebugPresenter()
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()
    private let settingsWindowPresenter = SettingsWindowPresenter()
    private let menuBarVisibilityMonitor = MenuBarVisibilityMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("[Muse] applicationDidFinishLaunching")
        AppStartupCoordinator.configureActivationPolicy()
        AppearanceController.start()  // 启动即设 app 级外观，让窗口创建前就定好，避免设置窗口首帧深色
        AppStartupCoordinator.runMigrations()
        AppStartupCoordinator.reconcileSelectedASRProviderIfNeeded()

        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        DebugFileLogger.log("launch args=\(ProcessInfo.processInfo.arguments.joined(separator: " "))")
        floatingBarController = FloatingBarController(state: appState)
        appState.onCopyFallbackVisibilityChange = { [weak self] isVisible in
            self?.hotkeyManager.isCopyFallbackVisible = isVisible
        }
        AppStartupCoordinator.scheduleDebugWindowsIfNeeded(
            hudDebugPresenter: hudDebugPresenter,
            appState: appState,
            openSettingsWindow: { [weak self] in
                self?.openSettingsWindow(preferManualWindow: true)
            }
        )

        // Bridge ASR events → AppState for floating bar display
        let session = self.session

        // 历史记录文本指标迁移（用 session 自带的 historyStore，迁移后 UI 能刷新）
        Task { await session.historyStore.migrateTextMetrics() }
        let appState = self.appState

        SoundFeedback.warmUp()

        // Pre-warm audio subsystem so the first recording starts instantly
        Task { await session.warmUp() }

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                Task { @MainActor in
                    appState.audioLevel.current = level
                }
            }
        }

        Task {
            await session.setOnASREvent { event in
                Task { @MainActor in
                    switch event {
                    case .ready:
                        AppLogger.log("[Muse] ready event received")
                        DebugFileLogger.log("ready event received, current barPhase=\(String(describing: appState.barPhase))")
                        appState.markRecordingReady()
                        guard appState.barPhase == .recording else {
                            DebugFileLogger.log("playStart skipped, barPhase=\(String(describing: appState.barPhase))")
                            return
                        }
                        AppLogger.log("[Muse] playStart firing")
                        DebugFileLogger.log("playStart firing")
                        SoundFeedback.playStart()
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        if appState.barPhase == .recording {
                            appState.stopRecording()
                        } else {
                            DebugFileLogger.log("completed ignored in barPhase=\(String(describing: appState.barPhase))")
                        }
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                        self.hotkeyManager.isProcessing = true
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .streamingInterrupted:
                        appState.showStreamingInterrupted()
                    case .error(let error):
                        appState.showError(AppErrorMessageFormatter.userFacingMessage(for: error))
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    }
                }
            }
        }

        // Start periodic update checking
        UpdateChecker.shared.startPeriodicChecking(appState: appState)
        appUpdater.checkPostUpdateStatus()

        // Reconcile current mode against the active provider before hotkeys are registered.
        refreshModeAvailability()

        // Re-register when modes change in Settings
        NotificationCenter.default.addObserver(
            forName: .modesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        // Suppress/resume hotkeys during hotkey recording
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = false
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startHotkeyWithRetry()
        }

        AppStartupCoordinator.showSetupWizardIfNeeded(appState: appState)
        AppStartupCoordinator.startLocalServerIfNeeded()
        // 启动静默探测三模型连通性，模型设置页的灯开箱即亮（2026-06-12）
        ModelConnectivityProber.probeOnLaunchIfNeeded()

        menuBarVisibilityMonitor.start()
    }

    private func refreshModeAvailability() {
        let provider = KeychainService.selectedASRProvider
        appState.reconcileCurrentMode(for: provider)
        registerHotkeys(for: provider)
    }

    private func registerHotkeys(for provider: ASRProvider) {
        let availableModes = appState.availableModes
        let modes = ASRProviderRegistry.supportedModes(from: availableModes, for: provider)
        let bindings: [ModeBinding] = modes.compactMap { mode in
            guard let code = mode.hotkeyCode else { return nil }
            let modifiers = CGEventFlags(rawValue: mode.hotkeyModifiers ?? 0)
            let capturedMode = mode
            return ModeBinding(
                modeId: mode.id,
                keyCode: CGKeyCode(code),
                modifiers: modifiers,
                style: capturedMode.hotkeyStyle,
                onStart: { [weak self] in
                    guard let self else { return }

                    // Safety: if already recording, the toggle state is out of sync.
                    // Redirect to stop so we don't discard accumulated text.
                    let alreadyRecording = MainActor.assumeIsolated {
                        self.appState.barPhase == .recording || self.appState.barPhase == .preparing
                    }
                    if alreadyRecording {
                        AppLogger.log("[Muse] >>> HOTKEY: toggle desync – onStart while recording, redirecting to STOP")
                        DebugFileLogger.log("hotkey toggle desync: onStart while recording, redirecting to stop")
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                        Task { @MainActor in self.appState.stopRecording() }
                        Task { await self.session.stopRecording() }
                        return
                    }

                    let selectedProvider = KeychainService.selectedASRProvider
                    let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                    let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                    MainActor.assumeIsolated { self.hotkeyManager.isSessionActive = true }
                    AppLogger.log("[Muse] >>> HOTKEY: Record START (mode: \(effectiveMode.name))")
                    DebugFileLogger.log("hotkey record start mode=\(effectiveMode.name)")
                    Task { @MainActor in
                        self.appState.currentMode = effectiveMode
                        self.appState.startRecording()
                    }
                    Task { await self.session.startRecording(mode: effectiveMode) }
                },
                onStop: { [weak self] in
                    guard let self else { return }
                    AppLogger.log("[Muse] >>> HOTKEY: Record STOP")
                    DebugFileLogger.log("hotkey record stop")
                    Task { @MainActor in
                        self.requestHotkeyStop(needsHoldFallback: capturedMode.hotkeyStyle == .hold)
                    }
                }
            )
        }
        hotkeyManager.registerBindings(bindings)

        // Cross-mode stop: user pressed mode B's key while mode A was recording.
        // Switch to mode B and stop, so the recording is processed with mode B.
        hotkeyManager.onCrossModeStop = { [weak self] newModeId in
            guard let self else { return }
            guard let newMode = availableModes.first(where: { $0.id == newModeId }) else { return }
            let selectedProvider = KeychainService.selectedASRProvider
            let resolvedMode = ASRProviderRegistry.resolvedMode(for: newMode, provider: selectedProvider)
            let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
            AppLogger.log("[Muse] >>> HOTKEY: Cross-mode stop → \(effectiveMode.name)")
            DebugFileLogger.log("hotkey cross-mode stop → \(effectiveMode.name)")
            Task { @MainActor in
                self.hotkeyManager.isSessionActive = true
                self.appState.currentMode = effectiveMode
                self.appState.stopRecording()
            }
            Task {
                await self.session.switchMode(to: effectiveMode)
                await self.session.stopRecording()
            }
        }

        // ESC abort: interrupt immediately. Do not register any alternate abort shortcut.
        hotkeyManager.onESCAbort = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let phase = self.appState.barPhase
                AppLogger.log("[Muse] >>> HOTKEY: ESC abort session (phase=\(String(describing: phase)))")
                DebugFileLogger.log("hotkey ESC abort session phase=\(phase)")
                self.hotkeyManager.isSessionActive = false
                self.appState.showCancelled()
            }
            Task {
                await self.session.abortCurrentSession()
            }
        }

        hotkeyManager.onESCDismissCopyFallback = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                DebugFileLogger.log("hotkey ESC dismiss copy fallback")
                self.appState.dismissCopyFallback()
            }
        }
    }

    private var retryTimer: Timer?
    private var hotkeyRetryCount = 0

    private func startHotkeyWithRetry() {
        let success = hotkeyManager.start()
        AppLogger.log("[Muse] Hotkey setup: \(success ? "OK" : "FAILED (need Accessibility permission)")")
        DebugFileLogger.log("hotkey setup \(success ? "OK" : "FAILED need accessibility")")

        if success {
            retryTimer?.invalidate()
            retryTimer = nil
            hotkeyRetryCount = 0
            return
        }

        // Prompt for accessibility and poll until granted
        PermissionManager.promptAccessibilityPermission()
        hotkeyRetryCount = 0
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(handleHotkeyRetry(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleHotkeyRetry(_ timer: Timer) {
        if PermissionManager.hasAccessibilityPermission {
            let ok = hotkeyManager.start()
            hotkeyRetryCount += 1
            AppLogger.log("[Muse] Hotkey retry #\(hotkeyRetryCount): \(ok ? "OK" : "still failing")")
            DebugFileLogger.log("hotkey retry #\(hotkeyRetryCount) \(ok ? "OK" : "still failing")")
            if ok {
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
            } else if hotkeyRetryCount >= 5 {
                // Permission granted but event tap still fails (macOS caches denial at kernel level).
                // Suggest restart.
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
                AppLogger.log("[Muse] Accessibility granted but hotkey tap failed after retries. Suggesting restart.")
                DebugFileLogger.log("hotkey retry failed after accessibility granted")
                showRestartAlert()
            }
        }
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("辅助功能权限已开启，但快捷键未生效", comment: "")
        alert.informativeText = NSLocalizedString(
            "macOS 有时需要重启应用才能激活全局快捷键。点击「重启」自动重启 Muse。",
            comment: ""
        )
        alert.addButton(withTitle: NSLocalizedString("重启", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("稍后", comment: ""))
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Relaunch the app
            let url = Bundle.main.bundleURL
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    /// Stored by MenuBarContent so AppDelegate can open the settings window.
    static var openSettingsAction: (() -> Void)?

    /// Stored by MenuBarContent so AppStartupCoordinator can open the setup wizard window.
    static var openSetupAction: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous kill: don't rely on async Task, app exits immediately after this returns
        SenseVoiceServerManager.killAllServerProcesses()
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        AppURLCommandHandler.handle(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func openSettingsWindow(preferManualWindow: Bool = false) {
        settingsWindowPresenter.open(
            preferManualWindow: preferManualWindow,
            appState: appState,
            appUpdater: appUpdater,
            swiftUIOpenAction: Self.openSettingsAction
        )
    }

    /// Only reset hotkey state when no new recording is in progress.
    /// Prevents a stale finalized/completed event from corrupting the toggle
    /// state of a recording that started after the event was emitted.
    private func safeResetHotkeyState() {
        let phase = appState.barPhase
        if phase == .recording || phase == .preparing {
            DebugFileLogger.log("safeResetHotkeyState: skipped (barPhase=\(phase))")
            return
        }
        hotkeyManager.resetActiveState()
    }

    private func requestHotkeyStop(needsHoldFallback: Bool = false) {
        Task { @MainActor in
            self.appState.stopRecording()
        }
        Task {
            await self.session.stopRecording()
        }

        guard needsHoldFallback else { return }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: holdHotkeyStopFallbackDelay)

            let shouldRetry = await MainActor.run {
                let phase = self.appState.barPhase
                return phase == .preparing || phase == .recording
            }
            guard shouldRetry else { return }

            DebugFileLogger.log("hotkey hold fallback stop retry")
            await MainActor.run {
                self.appState.stopRecording()
            }
            await self.session.stopRecording()
        }
    }

}
