import AppKit
import os

private struct ASRTeardownResult: Sendable {
    let providerIsStreaming: Bool
    let clean: Bool
}

private struct LLMPostProcessingResult: Sendable {
    var finalText: String
    var processedText: String?
    var llmFailed: Bool
}

actor RecognitionSession {

    // MARK: - State

    enum SessionState: Equatable, Sendable {
        case idle
        case starting
        case recording
        case finishing
        case injecting
        case postProcessing  // Phase 3
    }

    private(set) var state: SessionState = .idle

    var canStartRecording: Bool { state == .idle }

    /// Exposed for testing; production code should use startRecording / stopRecording.
    func setState(_ newState: SessionState) {
        state = newState
    }

    /// Exposed for testing; production code should resolve modes through startRecording / switchMode.
    func currentModeForTesting() -> ProcessingMode {
        currentMode
    }

    // MARK: - Dependencies

    private let audioEngine = AudioCaptureEngine()
    private let injectionEngine = TextInjectionEngine()
    let historyStore = HistoryStore()
    private var asrClient: (any SpeechRecognizer)?

    private let logger = Logger(
        subsystem: "pro.daliang.muse.session",
        category: "RecognitionSession"
    )

    /// REPAIR_PLAN J12：LLM 后处理的会话级硬超时。底层 request timeout(30s) 是
    /// 「无数据间隔」语义，流式慢速涓流可无限拖延；45s 高于底层正常超时（不抢跑），
    /// 超时按 LLM 失败处理回退原文，HUD 不再卡死在 postProcessing。
    static let llmPostProcessTimeout: Duration = .seconds(45)

    /// Return the appropriate LLM client for the currently selected provider.
    private func currentLLMClient() -> any LLMClient {
        LLMProviderRegistry.makeClient(for: KeychainService.selectedLLMProvider)
    }

    private func loadASRConfigOffActor(for provider: ASRProvider) async -> (any ASRProviderConfig)? {
        DebugFileLogger.log("ASR config load start provider=\(provider.rawValue)")
        let result: TimedValue<any ASRProviderConfig> = await AsyncTimeout.value(.milliseconds(900)) {
            KeychainService.loadASRConfig(for: provider)
        }
        if result.timedOut {
            DebugFileLogger.log("ASR config load timeout provider=\(provider.rawValue)")
        } else {
            DebugFileLogger.log("ASR config load done provider=\(provider.rawValue) hasConfig=\(result.value != nil)")
        }
        return result.value
    }

    private func loadLLMConfigOffActor() async -> LLMConfig? {
        let provider = KeychainService.selectedLLMProvider
        DebugFileLogger.log("LLM config load start provider=\(provider.rawValue)")
        let result: TimedValue<LLMConfig> = await AsyncTimeout.value(.milliseconds(900)) {
            KeychainService.loadLLMConfig()
        }
        if result.timedOut {
            DebugFileLogger.log("LLM config load timeout provider=\(provider.rawValue)")
        } else {
            DebugFileLogger.log("LLM config load done provider=\(provider.rawValue) hasConfig=\(result.value != nil)")
        }
        return result.value
    }

    /// Pre-initialize audio subsystem so the first recording starts instantly.
    func warmUp() { audioEngine.warmUp() }

    // MARK: - Mode & Timing

    private var currentMode: ProcessingMode = .direct
    private var recordingStartTime: Date?
    private var currentConfig: (any ASRProviderConfig)?
    /// The ASR provider for the current session, captured at start time.
    /// stopRecording reads this, not the global setting.
    private var activeProvider: ASRProvider = .volcano

    // MARK: - UI Callback

    /// Called on every ASR event so the UI layer can update.
    /// Set by AppDelegate to bridge actor → @MainActor.
    private var onASREvent: (@Sendable (RecognitionEvent) -> Void)?

    func setOnASREvent(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) {
        onASREvent = handler
    }

    /// Called with normalized audio level (0..1) for UI visualization.
    private var onAudioLevel: (@Sendable (Float) -> Void)?

    func setOnAudioLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        onAudioLevel = handler
    }

    // MARK: - Session generation (prevents zombie tasks after forceReset)

    private var sessionGeneration: Int = 0

    // MARK: - Accumulated text

    private var currentTranscript: RecognitionTranscript = .empty
    private var eventConsumptionTask: Task<Void, Never>?
    private var hasEmittedReadyForCurrentSession = false
    private var audioChunkPipeline: AudioChunkUploadPipeline?
    /// REPAIR_PLAN B7b：本次会话流式是否降级（断流/重连过），停止时强制批量复核
    private var streamingDegraded = false

    // MARK: - Prompt context (selected text + clipboard captured at recording start)

    private var promptContext: PromptContext = PromptContext(selectedText: "", clipboardText: "")

    // MARK: - Speculative LLM (fire during recording pauses)

    private var speculativeLLMTask: Task<String?, Never>?
    private var speculativeLLMText: String = ""
    private var speculativeDebounceTask: Task<Void, Never>?
    /// Stores the last LLM error from the early/fresh LLM task, consumed once by stopRecording().
    private var pendingLLMError: Error?
    /// When true, skip text injection (paste) but still save to clipboard & history.
    private var injectionAborted = false

    // MARK: - Toggle

    func toggleRecording() async {
        switch state {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        default:
            logger.warning("toggleRecording ignored in state: \(String(describing: self.state))")
        }
    }

    // MARK: - Start

    func startRecording(mode: ProcessingMode = .direct) async {
        if state != .idle {
            AppLogger.log("[Session] startRecording: forcing reset from state=\(String(describing: state))")
            DebugFileLogger.log("session forcing reset from state=\(state)")
            await forceReset()
        }

        let provider = KeychainService.selectedASRProvider
        activeProvider = provider
        let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
        sessionGeneration &+= 1
        let myGeneration = sessionGeneration
        DebugFileLogger.log("startRecording begin mode=\(effectiveMode.name) provider=\(provider.rawValue) generation=\(myGeneration)")

        self.currentMode = effectiveMode
        self.recordingStartTime = nil
        hasEmittedReadyForCurrentSession = false
        injectionAborted = false
        pendingLLMError = nil
        streamingDegraded = false
        state = .starting

        // Load credentials for selected provider
        let config: any ASRProviderConfig

        let savedConfig = await loadASRConfigOffActor(for: provider)
        guard sessionGeneration == myGeneration, state == .starting else {
            DebugFileLogger.log("startRecording: cancelled during ASR config load, bailing")
            return
        }

        if provider.isLocal {
            // Local providers: use default model directory if no saved config
            if let savedConfig {
                config = savedConfig
                AppLogger.log("[Session] Loaded \(provider.rawValue) config from file store")
            } else if let defaultConfig = SherpaASRConfig(credentials: ["modelDir": ModelManager.defaultModelsDir]) {
                config = defaultConfig
                AppLogger.log("[Session] Using default model directory for \(provider.rawValue)")
            } else {
                AppLogger.log("[Session] Failed to create default config for \(provider.rawValue)!")
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: L("本地模型未配置", "Local model not configured")])))
                onASREvent?(.completed)
                return
            }
            // Verify required models are downloaded
            if !ModelManager.shared.areRequiredModelsAvailable() {
                AppLogger.log("[Session] Required local models not downloaded for \(provider.rawValue)")
                SoundFeedback.playError()
                state = .idle
                onASREvent?(.error(NSError(domain: "Muse", code: -3, userInfo: [NSLocalizedDescriptionKey: L("请先下载识别模型", "Please download ASR models first")])))
                onASREvent?(.completed)
                return
            }
        } else if let savedConfig {
            config = savedConfig
            AppLogger.log("[Session] Loaded \(provider.rawValue) credentials from file store")
        } else if provider == .volcano,
                  let appKey = ProcessInfo.processInfo.environment["VOLC_APP_KEY"],
                  let accessKey = ProcessInfo.processInfo.environment["VOLC_ACCESS_KEY"] {
            // Env var fallback (volcano only, for dev convenience)
            let resourceId = ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? VolcanoASRConfig.resourceIdSeedASR
            let volcConfig = VolcanoASRConfig(credentials: [
                "appKey": appKey, "accessKey": accessKey, "resourceId": resourceId,
            ])!
            try? KeychainService.saveASRCredentials(appKey: appKey, accessKey: accessKey, resourceId: resourceId)
            config = volcConfig
            AppLogger.log("[Session] Loaded credentials from env vars and persisted to file")
        } else {
            AppLogger.log("[Session] No ASR credentials found for provider=\(provider.rawValue)!")
            SoundFeedback.playError()
            state = .idle
            onASREvent?(.error(NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: L("未配置 API 凭证", "API credentials not configured")])))
            onASREvent?(.completed)
            return
        }

        self.currentConfig = config

        guard let client = ASRProviderRegistry.createClient(for: provider) else {
            AppLogger.log("[Session] No client implementation for provider=\(provider.rawValue)")
            SoundFeedback.playError()
            state = .idle
            onASREvent?(.error(NSError(domain: "Muse", code: -2, userInfo: [NSLocalizedDescriptionKey: L("\(provider.displayName) 暂不支持", "\(provider.displayName) not yet supported")])))
            onASREvent?(.completed)
            return
        }
        self.asrClient = client

        // Load hotwords（用户词优先置前 + 内置词补到上限,见 loadEffectiveForASR）
        let effectiveHotwords = HotwordStorage.loadEffectiveForASR()
        let biasSettings = ASRBiasSettingsStorage.load()
        let needsLLM = !effectiveMode.prompt.isEmpty
        let requestOptions = ASRRequestOptions(
            enablePunc: !needsLLM,
            hotwords: effectiveHotwords.words,
            userHotwordCount: effectiveHotwords.userCount,
            boostingTableID: biasSettings.boostingTableID,
            contextHistoryLength: biasSettings.contextHistoryLength
        )

        // Capture prompt context while the user's selection is still active.
        DebugFileLogger.log("prompt context capture start")
        promptContext = await PromptContext.capture()
        DebugFileLogger.log("prompt context capture done")
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("startRecording: zombie detected after capture, bailing")
            return
        }

        // Reset text state and clean up previous pipeline
        currentTranscript = .empty
        DebugFileLogger.log("audio pipeline cleanup start")
        await finishAudioChunkPipeline(timeout: .milliseconds(100))
        DebugFileLogger.log("audio pipeline cleanup done")
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("startRecording: zombie detected after pipeline cleanup, bailing")
            return
        }

        // ── Phase 1: Start recording immediately (before ASR connects) ──
        // Audio chunks are buffered while WebSocket handshake is in progress.
        // This eliminates the ~1s perceived latency from connect().

        let audioBuffer = AudioChunkBuffer()

        let levelHandler = self.onAudioLevel
        audioEngine.setAudioHandlers(
            onChunk: { [weak self] data in
                guard self != nil else { return }
                audioBuffer.append(data)
            },
            onLevel: { level in
                levelHandler?(level)
            }
        )

        DebugFileLogger.log("microphone permission check start")
        if !PermissionManager.hasMicrophonePermission {
            let granted = await PermissionManager.requestMicrophonePermission()
            guard granted else {
                AppLogger.log("[Session] Microphone permission denied")
                DebugFileLogger.log("microphone permission denied before audio start")
                SoundFeedback.playError()
                await client.disconnect()
                self.asrClient = nil
                audioEngine.clearAudioHandlers()
                state = .idle
                onASREvent?(.error(AudioCaptureError.microphonePermissionDenied))
                onASREvent?(.completed)
                return
            }
        }
        DebugFileLogger.log("microphone permission check done")

        do {
            try audioEngine.start()
            AppLogger.log("[Session] Audio engine started OK")
            DebugFileLogger.log("audio engine started OK")
        } catch {
            AppLogger.log("[Session] Audio engine start FAILED: \(String(describing: error))")
            DebugFileLogger.log("audio engine start failed: \(String(describing: error))")
            SoundFeedback.playError()
            await client.disconnect()
            self.asrClient = nil
            state = .idle
            onASREvent?(.error(error))
            onASREvent?(.completed)
            return
        }

        state = .recording
        markReadyIfNeeded()
        DebugFileLogger.log("session entered recording state (buffering, ASR connecting)")

        // ── Phase 2: Connect ASR (audio is already recording) ──

        do {
            DebugFileLogger.log("ASR connecting provider=\(provider.rawValue)")
            try await client.connect(config: config, options: requestOptions)
            AppLogger.log("[Session] ASR connected OK (streaming, hotwords=\(effectiveHotwords.words.count), history=\(requestOptions.contextHistoryLength))")
            DebugFileLogger.log("ASR connected OK provider=\(provider.rawValue)")
        } catch {
            AppLogger.log("[Session] ASR connect FAILED provider=\(provider.rawValue) error=\(String(describing: error))")
            DebugFileLogger.log("ASR connect failed provider=\(provider.rawValue): \(String(describing: error))")
            audioEngine.stop()
            audioEngine.clearAudioHandlers()
            await client.disconnect()
            self.asrClient = nil
            hasEmittedReadyForCurrentSession = false

            // 快速启停竞态（2026-07 修）：用户已取消/会话已被顶替时，连接失败只是被掐断的余波——
            // 静默清理即可，不响错误音、不往 HUD 糊报错
            guard sessionGeneration == myGeneration, state == .recording else {
                DebugFileLogger.log("ASR connect failed after cancel/supersede, suppressed (gen=\(myGeneration) current=\(sessionGeneration) state=\(state))")
                if state == .recording { state = .idle }
                return
            }

            state = .idle
            SoundFeedback.playError()
            onASREvent?(.error(error))
            onASREvent?(.completed)
            return
        }

        // Bail out if session was superseded or user stopped while we were connecting
        guard sessionGeneration == myGeneration, state == .recording else {
            DebugFileLogger.log("startRecording: zombie or state change after connect (gen=\(myGeneration) current=\(sessionGeneration) state=\(state)), bailing")
            await client.disconnect()
            self.asrClient = nil
            return
        }

        // ── Phase 3: Flush buffer → switch to live pipeline ──

        let events = await client.events
        let expectedGeneration = sessionGeneration
        eventConsumptionTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.handleASREvent(event, expectedGeneration: expectedGeneration)
                if case .completed = event { break }
            }
        }

        let audioUploadPipeline = setupAudioChunkPipeline()

        // Flush all chunks buffered during connect
        let bufferedChunks = audioBuffer.drain()
        for chunk in bufferedChunks {
            audioUploadPipeline.yield(chunk)
        }

        // Switch callback from buffer to live pipeline
        audioEngine.setAudioChunkHandler { [weak self, weak audioUploadPipeline] data in
            guard self != nil else { return }
            audioUploadPipeline?.yield(data)
        }

        // Catch any chunks that arrived between drain and callback switch
        for chunk in audioBuffer.drain() {
            audioUploadPipeline.yield(chunk)
        }

        DebugFileLogger.log("ASR pipeline live, flushed \(bufferedChunks.count) buffered chunks")

        // Pre-warm LLM connection for modes with post-processing
        if !currentMode.prompt.isEmpty {
            let llmConfig = await loadLLMConfigOffActor()
            guard sessionGeneration == myGeneration, state == .recording else {
                DebugFileLogger.log("startRecording: cancelled during LLM prewarm config load, bailing")
                return
            }
            if let llmConfig {
                let client = currentLLMClient()
                Task { await client.warmUp(baseURL: llmConfig.baseURL) }
            }
        }
    }

    /// Switch the processing mode before stopping. Used for cross-mode hotkey stops.
    func switchMode(to mode: ProcessingMode) {
        currentMode = ASRProviderRegistry.resolvedMode(for: mode, provider: activeProvider)
    }

    // MARK: - Stop

    /// Cancel an in-progress recording: tear down all resources without injecting any text.
    func cancelRecording() async {
        guard state == .recording || state == .starting else {
            logger.warning("cancelRecording called but state is \(String(describing: self.state))")
            return
        }
        DebugFileLogger.log("cancelRecording: discarding session from state=\(state)")
        await forceReset()
    }

    /// ESC means interrupt immediately: no post-processing, no clipboard write, no injection.
    func abortCurrentSession() async {
        guard state != .idle else {
            DebugFileLogger.log("abortCurrentSession idle: emit completed for UI cleanup")
            injectionAborted = true
            onASREvent?(.completed)
            return
        }
        DebugFileLogger.log("abortCurrentSession: force reset from state=\(state)")
        injectionAborted = true
        await forceReset()
        onASREvent?(.completed)
    }

    /// Mark that injection should be skipped. Recognition, clipboard, and history still proceed.
    func abortInjection() {
        injectionAborted = true
        DebugFileLogger.log("abortInjection: injection will be skipped")
    }

    func stopRecording() async {
        let myGeneration = sessionGeneration
        if state == .starting {
            DebugFileLogger.log("stopRecording during starting: cancelling pending session")
            await forceReset()
            return
        }
        guard state == .recording else {
            logger.warning("stopRecording called but state is \(String(describing: self.state))")
            return
        }

        func ensureCurrent(_ stage: String) -> Bool {
            guard sessionGeneration == myGeneration else {
                DebugFileLogger.log("stopRecording: superseded during \(stage), bailing")
                return false
            }
            return true
        }

        // Set state BEFORE any await to prevent a second stop from
        // slipping through the guard during the suspension point.
        state = .finishing

        let stopT0 = ContinuousClock.now
        SoundFeedback.playStop()

        // Stop capture first so flushRemaining() can emit the tail audio chunk.
        audioEngine.stop()
        audioEngine.clearAudioHandlers()
        let uploadFailed = await finishAudioChunkPipeline()
        DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("stopRecording: zombie after audio pipeline, bailing")
            return
        }

        // Keep speculative LLM task alive — we'll compare its input text
        // against the final ASR transcript after full teardown.
        cancelSpeculativeLLM()
        let needsLLM = !currentMode.prompt.isEmpty
        let provider = activeProvider

        let asrTeardown = await teardownASRClient(provider: provider, stopStartedAt: stopT0)

        let earlyLLMTask = await prepareEarlyLLMTask(
            needsLLM: needsLLM,
            canEarlyLLM: asrTeardown.providerIsStreaming,
            expectedGeneration: myGeneration,
            stopStartedAt: stopT0
        )
        guard sessionGeneration == myGeneration else {
            DebugFileLogger.log("stopRecording: zombie after ASR teardown, bailing")
            return
        }

        // Batch fallback: if streaming broke mid-session, always retry with
        // the full local recording to get complete text, even if we have partial.
        let streamingFailed = uploadFailed || !asrTeardown.clean
            || streamingDegraded
        await recoverTranscriptAfterStreamingFailureIfNeeded(
            streamingFailed: streamingFailed,
            expectedGeneration: myGeneration
        )
        guard ensureCurrent("batch fallback") else { return }
        // Combine confirmed segments + any trailing unconfirmed partial.
        let effectiveText = currentTranscript.displayText
        currentConfig = nil

        if !effectiveText.isEmpty {
            let rawText = effectiveText
            guard let llmResult = await postProcessRecognizedText(
                rawText: rawText,
                needsLLM: needsLLM,
                earlyLLMTask: earlyLLMTask,
                expectedGeneration: myGeneration,
                stopStartedAt: stopT0
            ) else { return }
            guard ensureCurrent("pre-injection") else { return }

            let injectionOutcome = injectFinalText(
                llmResult.finalText,
                stopStartedAt: stopT0
            )
            guard ensureCurrent("post-injection") else { return }
            onASREvent?(.finalized(text: llmResult.finalText, injection: injectionOutcome))

            await saveSuccessfulHistory(
                rawText: rawText,
                llmResult: llmResult,
                streamingFailed: streamingFailed
            )

        } else {
            await saveEmptyHistoryIfNeeded(streamingFailed: streamingFailed)
            guard ensureCurrent("empty completion") else { return }
            onASREvent?(.processingResult(text: ""))
            onASREvent?(.completed)
        }

        // Only reset to idle if this is still the active session.
        if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
        }
        resetSpeculativeLLM()
        logger.info("Session complete, injected \(effectiveText.count) chars")
    }

    // MARK: - Stop Helpers

    private func prepareEarlyLLMTask(
        needsLLM: Bool,
        canEarlyLLM: Bool,
        expectedGeneration: Int,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> Task<String?, Never>? {
        guard needsLLM && canEarlyLLM else { return nil }

        var finalASRText = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        finalASRText = SnippetStorage.applyEffective(to: finalASRText)
        DebugFileLogger.log("stop: needsLLM=true mode=\(currentMode.name) text=\(finalASRText.count)chars specMatch=\(finalASRText == speculativeLLMText)")
        guard !finalASRText.isEmpty else { return nil }

        if finalASRText == speculativeLLMText, let specTask = speculativeLLMTask {
            // Final transcript matches speculative input — reuse (may already be done!)
            state = .postProcessing
            DebugFileLogger.log("stop: reusing speculative LLM +\(ContinuousClock.now - stopT0)")
            return specTask
        }

        guard let llmConfig = await loadLLMConfigOffActor() else { return nil }
        guard sessionGeneration == expectedGeneration else {
            DebugFileLogger.log("stopRecording: superseded during fresh llm config, bailing")
            return nil
        }

        // Final transcript differs from speculative input (tail words arrived),
        // discard stale result and fire fresh LLM with complete text.
        speculativeLLMTask?.cancel()
        let mode = currentMode
        let prompt = mode.applyingLLMFormatGuard(
            to: promptContext.expandContextVariables(mode.prompt)
        )
        let client = currentLLMClient()
        state = .postProcessing
        if finalASRText != speculativeLLMText {
            DebugFileLogger.log("stop: final transcript changed (spec=\(speculativeLLMText.count)chars final=\(finalASRText.count)chars), firing fresh LLM")
        }
        DebugFileLogger.log("stop: fresh LLM firing mode=\(mode.name) model=\(llmConfig.model) with \(finalASRText.count) chars +\(ContinuousClock.now - stopT0)")

        return Task {
            do {
                let result = try await client.process(
                    text: finalASRText, prompt: prompt, config: llmConfig
                )
                let cleanedResult = mode.applyingLLMResultCleanup(to: result)
                DebugFileLogger.log("stop: fresh LLM done \(cleanedResult.count) chars +\(ContinuousClock.now - stopT0)")
                return cleanedResult
            } catch {
                DebugFileLogger.log("stop: fresh LLM FAILED +\(ContinuousClock.now - stopT0) error=\(error)")
                self.setPendingLLMError(error)
                return nil
            }
        }
    }

    private func postProcessRecognizedText(
        rawText: String,
        needsLLM: Bool,
        earlyLLMTask: Task<String?, Never>?,
        expectedGeneration: Int,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> LLMPostProcessingResult? {
        var finalText = SnippetStorage.applyEffective(to: rawText)
        var processedText: String?
        var llmFailed = false

        // LLM post-processing: prefer early result (fired at stop time),
        // fall back to synchronous call for very short recordings where
        // no streaming text was available yet.
        if let earlyTask = earlyLLMTask {
            state = .postProcessing
            DebugFileLogger.log("stop: awaiting early LLM result +\(ContinuousClock.now - stopT0)")
            // REPAIR_PLAN J12：stop 链路上 LLM 是唯一无会话级硬超时的阻塞点——底层
            // 30s request timeout 是「无数据间隔」语义，流式慢速涓流可拖过；超时按
            // LLM 失败处理（下方 else 分支回退原文），HUD 不再无限卡 postProcessing。
            let timedEarly = await AsyncTimeout.asyncValue(Self.llmPostProcessTimeout) {
                await earlyTask.value
            }
            if timedEarly.timedOut {
                DebugFileLogger.log("stop: early LLM timed out at session level")
            }
            let earlyResult = timedEarly.value.flatMap { $0 }
            guard sessionGeneration == expectedGeneration else {
                DebugFileLogger.log("stopRecording: superseded during early llm, bailing")
                return nil
            }
            if let result = earlyResult, !result.isEmpty {
                DebugFileLogger.log("stop: early LLM result received \(result.count) chars +\(ContinuousClock.now - stopT0)")
                processedText = result
                finalText = result
                onASREvent?(.processingResult(text: result))
            } else {
                let err = pendingLLMError ?? LLMError.emptyResponse(nil)
                DebugFileLogger.log("stop: early LLM failed, falling back to raw text: \(err)")
                pendingLLMError = nil
                llmFailed = true
                onASREvent?(.processingResult(text: rawText))
            }
        } else if needsLLM {
            state = .postProcessing
            if let llmConfig = await loadLLMConfigOffActor() {
                guard sessionGeneration == expectedGeneration else {
                    DebugFileLogger.log("stopRecording: superseded during sync llm config, bailing")
                    return nil
                }

                let mode = currentMode
                let prompt = mode.applyingLLMFormatGuard(
                    to: promptContext.expandContextVariables(mode.prompt)
                )
                DebugFileLogger.log("stop: sync LLM firing mode=\(mode.name) model=\(llmConfig.model) with \(finalText.count) chars")
                do {
                    let client = currentLLMClient()
                    // REPAIR_PLAN J12：同 early 路径，包会话级硬超时防涓流拖死
                    let textForLLM = finalText
                    let timed = await AsyncTimeout.asyncValue(Self.llmPostProcessTimeout) {
                        () -> Result<String, Error> in
                        do {
                            return .success(try await client.process(
                                text: textForLLM,
                                prompt: prompt,
                                config: llmConfig
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                    guard let outcome = timed.value else {
                        throw LLMError.timedOut
                    }
                    let result = try outcome.get()
                    let cleanedResult = mode.applyingLLMResultCleanup(to: result)
                    guard sessionGeneration == expectedGeneration else {
                        DebugFileLogger.log("stopRecording: superseded during sync llm, bailing")
                        return nil
                    }
                    if cleanedResult.isEmpty {
                        DebugFileLogger.log("stop: sync LLM empty result, falling back to raw text")
                        llmFailed = true
                        onASREvent?(.processingResult(text: rawText))
                    } else {
                        processedText = cleanedResult
                        finalText = cleanedResult
                        onASREvent?(.processingResult(text: cleanedResult))
                    }
                } catch {
                    guard sessionGeneration == expectedGeneration else {
                        DebugFileLogger.log("stopRecording: superseded during sync llm error, bailing")
                        return nil
                    }
                    logger.error("LLM failed: \(error)")
                    DebugFileLogger.log("stop: sync LLM FAILED, falling back to raw text: \(error)")
                    llmFailed = true
                    onASREvent?(.processingResult(text: rawText))
                }
            } else {
                DebugFileLogger.log("stop: no LLM credentials, falling back to raw text")
                llmFailed = true
                onASREvent?(.processingResult(text: rawText))
            }
        }

        let insertionCleanedText = currentMode.applyingFinalInsertionCleanup(to: finalText)
        if insertionCleanedText != finalText {
            DebugFileLogger.log(
                "stop: final insertion cleanup changed text len \(finalText.count)->\(insertionCleanedText.count)"
            )
            finalText = insertionCleanedText
            if processedText != nil {
                processedText = insertionCleanedText
            }
        }

        return LLMPostProcessingResult(
            finalText: finalText,
            processedText: processedText,
            llmFailed: llmFailed
        )
    }

    private func injectFinalText(
        _ finalText: String,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) -> InjectionOutcome {
        state = .injecting
        let defaults = UserDefaults.standard
        injectionEngine.preserveClipboard = defaults.object(forKey: DefaultsKeys.preserveClipboard) != nil
            ? defaults.bool(forKey: DefaultsKeys.preserveClipboard)
            : true

        if injectionAborted {
            // Manual injection abort: copy to clipboard for manual paste, skip injection.
            // ESC interruption uses abortCurrentSession() and does not enter this path.
            injectionEngine.copyToClipboard(finalText)
            DebugFileLogger.log("stop: injection aborted by ESC, text saved to clipboard & history")
            return .copiedToClipboard
        }

        DebugFileLogger.log("stop: injecting method=clipboard len=\(finalText.count) +\(ContinuousClock.now - stopT0)")
        return injectionEngine.inject(finalText)
    }

    private func saveSuccessfulHistory(
        rawText: String,
        llmResult: LLMPostProcessingResult,
        streamingFailed: Bool
    ) async {
        let status: String
        if injectionAborted { status = "aborted" }
        else if llmResult.llmFailed { status = "llm_error" }
        else if streamingFailed { status = "stream_recovered" }
        else { status = "completed" }

        let finalText = llmResult.finalText
        await historyStore.insert(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0,
            rawText: rawText,
            processingMode: currentMode.id == ProcessingMode.directId ? nil : currentMode.name,
            processedText: llmResult.processedText,
            finalText: finalText,
            status: status,
            characterCount: finalText.count,
            tokenCount: EstimatedTokenCounter.count(in: finalText)
        ))

        // REPAIR_PLAN C1：按保留上限裁剪（默认 1 万条，defaults 可调）
        let defaults = UserDefaults.standard
        let retentionLimit = defaults.object(forKey: DefaultsKeys.historyRetentionLimit) != nil
            ? defaults.integer(forKey: DefaultsKeys.historyRetentionLimit)
            : HistoryStore.defaultRetentionLimit
        await historyStore.prune(keepingMostRecent: retentionLimit)
    }

    private func saveEmptyHistoryIfNeeded(streamingFailed: Bool) async {
        // No text recognized: save to history as failed, then exit.
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        guard duration > 1.0 else { return }

        // Only save if recording lasted more than 1 second (skip accidental taps)
        let status = streamingFailed ? "stream_failed" : "empty"
        await historyStore.insert(HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: duration,
            rawText: "",
            processingMode: currentMode.id == ProcessingMode.directId ? nil : currentMode.name,
            processedText: nil,
            finalText: "",
            status: status,
            characterCount: 0,
            tokenCount: 0
        ))
        DebugFileLogger.log("stop: no text recognized, saved to history as \(status)")
    }

    private func teardownASRClient(
        provider: ASRProvider,
        stopStartedAt stopT0: ContinuousClock.Instant
    ) async -> ASRTeardownResult {
        // ASR teardown: send endAudio and drain event stream with hard deadlines.
        // Uses detached tasks + continuation so a stuck client can't block stopRecording.
        let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
        var clean = true

        defer {
            eventConsumptionTask = nil
            asrClient = nil
            hasEmittedReadyForCurrentSession = false
        }

        guard let client = asrClient else {
            return ASRTeardownResult(providerIsStreaming: providerIsStreaming, clean: clean)
        }

        let endAudioTimeout: Duration = providerIsStreaming ? .seconds(3) : .seconds(60)
        let endAudioOK = await AsyncTimeout.run(endAudioTimeout) {
            try await client.endAudio()
        }
        if !endAudioOK {
            DebugFileLogger.log("endAudio timeout or failed")
            clean = false
        }

        // Always try to drain events — even if endAudio failed, the server
        // may have already queued transcript events before the connection broke.
        if let evtTask = eventConsumptionTask {
            let drainTimeout: Duration = providerIsStreaming ? .seconds(2) : .seconds(5)
            let drained = await AsyncTimeout.run(drainTimeout) {
                await evtTask.value
            }
            if !drained {
                DebugFileLogger.log("event stream drain timeout")
                clean = false
            }
        }

        await client.disconnect()
        eventConsumptionTask?.cancel()
        DebugFileLogger.log("stop: ASR teardown complete (clean=\(clean)) +\(ContinuousClock.now - stopT0)")
        return ASRTeardownResult(providerIsStreaming: providerIsStreaming, clean: clean)
    }

    private func recoverTranscriptAfterStreamingFailureIfNeeded(
        streamingFailed: Bool,
        expectedGeneration: Int
    ) async {
        guard streamingFailed else { return }

        let partialText = currentTranscript.composedText
        DebugFileLogger.log("stop: streaming failed (partial=\(partialText.count) chars), attempting batch fallback")

        let fullAudio = audioEngine.getRecordedAudio()
        guard !fullAudio.isEmpty, let config = currentConfig else { return }

        onASREvent?(.processingResult(text: partialText.isEmpty ? "重新识别中..." : partialText))
        guard let batchText = await attemptBatchFallback(audio: fullAudio, config: config) else {
            DebugFileLogger.log("stop: batch fallback failed, using partial text")
            return
        }
        guard sessionGeneration == expectedGeneration else {
            DebugFileLogger.log("stop: batch fallback result ignored for stale generation")
            return
        }

        currentTranscript = RecognitionTranscript(
            confirmedSegments: [batchText],
            partialText: "",
            authoritativeText: batchText,
            isFinal: true
        )
        DebugFileLogger.log("stop: batch fallback succeeded, \(batchText.count) chars")
    }

    // MARK: - ASR Events

    private func handleASREvent(_ event: RecognitionEvent, expectedGeneration: Int) {
        guard expectedGeneration == sessionGeneration else {
            DebugFileLogger.log("ignoring stale ASR event for gen=\(expectedGeneration), active=\(sessionGeneration)")
            return
        }
        switch event {
        case .ready:
            // Deduplicate: ASR clients may emit .ready, but we also emit it
            // on first audio chunk via markReadyIfNeeded(). Route both through
            // the same guard to avoid double-firing the start sound.
            markReadyIfNeeded()
            return  // markReadyIfNeeded calls onASREvent(.ready) internally

        default:
            break
        }

        // Notify UI layer for all non-ready events
        onASREvent?(event)

        switch event {
        case .ready:
            break  // handled above

        case .transcript(let transcript):
            currentTranscript = transcript
            logger.info("Transcript updated: \(transcript.displayText)")
            if state == .recording && !currentMode.prompt.isEmpty {
                scheduleSpeculativeLLM()
            }

        case .error(let error):
            logger.error("ASR error: \(error)")
            if state == .recording || state == .starting {
                let generation = sessionGeneration
                Task { await self.failActiveSessionAfterASRError(expectedGeneration: generation) }
            }

        case .completed:
            logger.info("ASR stream completed")
            if state == .recording {
                AppLogger.log("[Session] Server closed ASR while recording, initiating stop")
                DebugFileLogger.log("server-initiated stop from recording state")
                Task { await self.stopRecording() }
            }

        case .streamingInterrupted:
            // REPAIR_PLAN B7b：客户端静默重连成功也会发此事件——重连期间的
            // 语音服务端没听到，标记降级让停止流程批量复核全文
            streamingDegraded = true
            logger.warning("streaming degraded (interrupted/reconnected); batch fallback will verify at stop")

        case .processingResult, .finalized:
            break
        }
    }

    private func failActiveSessionAfterASRError(expectedGeneration: Int) async {
        guard expectedGeneration == sessionGeneration else { return }
        guard state == .recording || state == .starting else { return }
        DebugFileLogger.log("ASR error forced session teardown state=\(state)")
        await forceReset()
        onASREvent?(.completed)
    }

    // MARK: - Internal helpers

    private func setupAudioChunkPipeline() -> AudioChunkUploadPipeline {
        audioChunkPipeline?.cancel()
        // Capture everything needed for sending so the Task body
        // does NOT hop back to the actor.  This prevents a blocking
        // WebSocket send from starving stopRecording().
        let client = asrClient
        let audioInput = ASRProviderRegistry.capabilities(for: activeProvider).audioInput
        // REPAIR_PLAN B7a：中断瞬间直通 UI（AppState 侧有 recording 相位守卫，
        // 过期事件天然无害），不经 handleASREvent 以免 detached 任务回跳 actor
        let emitInterrupted = self.onASREvent

        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: audioInput,
            emitInterrupted: emitInterrupted
        )
        audioChunkPipeline = pipeline
        return pipeline
    }

    @discardableResult
    private func finishAudioChunkPipeline(timeout: Duration = .seconds(1)) async -> Bool {
        // Give the detached sender a brief window to drain remaining chunks
        // (especially the tail audio from flushRemaining). Since it's detached,
        // this wait does NOT block the actor.
        guard let pipeline = audioChunkPipeline else { return false }
        let failed = await pipeline.finish(timeout: timeout)
        audioChunkPipeline = nil
        return failed
    }

    private func markReadyIfNeeded() {
        guard !hasEmittedReadyForCurrentSession else { return }
        hasEmittedReadyForCurrentSession = true
        recordingStartTime = Date()
        DebugFileLogger.log("session emitting ready")
        onASREvent?(.ready)
        logger.info("Recording started")
    }

    // MARK: - Speculative LLM

    /// Debounce: after each transcript update, wait 800ms of silence before
    /// speculatively sending current text to LLM. If the user is still
    /// speaking, the timer resets.
    private func scheduleSpeculativeLLM() {
        // Skip speculative LLM for local models — they're fast enough (~0.5s)
        // and would compete for Metal GPU with local ASR.
        guard KeychainService.selectedLLMProvider != .localQwen else { return }

        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, state == .recording else { return }
            await fireSpeculativeLLM()
        }
    }

    private func fireSpeculativeLLM() async {
        var text = currentTranscript.composedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = SnippetStorage.applyEffective(to: text)
        guard !text.isEmpty, text != speculativeLLMText else { return }
        guard let llmConfig = await loadLLMConfigOffActor() else { return }
        guard state == .recording else { return }

        // Cancel previous speculative call if text changed
        speculativeLLMTask?.cancel()
        speculativeLLMText = text
        let prompt = currentMode.applyingLLMFormatGuard(
            to: promptContext.expandContextVariables(currentMode.prompt)
        )

        let client = currentLLMClient()
        DebugFileLogger.log("speculative LLM: firing mode=\(currentMode.name) model=\(llmConfig.model) with \(text.count) chars")
        speculativeLLMTask = Task {
            do {
                let result = try await client.process(
                    text: text, prompt: prompt, config: llmConfig
                )
                let cleanedResult = currentMode.applyingLLMResultCleanup(to: result)
                DebugFileLogger.log("speculative LLM: done \(cleanedResult.count) chars")
                return cleanedResult
            } catch {
                DebugFileLogger.log("speculative LLM: failed \(error)")
                self.setPendingLLMError(error)
                return nil
            }
        }
    }

    private func cancelSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        // Don't cancel speculativeLLMTask here — stopRecording may reuse it
    }

    private func setPendingLLMError(_ error: Error) {
        pendingLLMError = error
    }

    private func resetSpeculativeLLM() {
        speculativeDebounceTask?.cancel()
        speculativeDebounceTask = nil
        speculativeLLMTask?.cancel()
        speculativeLLMTask = nil
        speculativeLLMText = ""
    }

    // MARK: - Batch Fallback

    /// Try to transcribe full audio via the same provider in a fresh connection.
    private func attemptBatchFallback(audio: Data, config: any ASRProviderConfig) async -> String? {
        let provider = activeProvider
        let resultTask = Task.detached { () -> String? in
            guard let client = ASRProviderRegistry.createClient(for: provider) else { return nil }
            do {
                let options = ASRRequestOptions(enablePunc: true, contextHistoryLength: 0)
                try await client.connect(config: config, options: options)
                // Send all audio at once, then signal end
                try await client.sendAudio(audio)
                try await client.endAudio()

                // Wait for final transcript
                let events = await client.events
                for await event in events {
                    switch event {
                    case .transcript(let transcript) where transcript.isFinal:
                        await client.disconnect()
                        let text = transcript.authoritativeText.isEmpty
                            ? transcript.composedText : transcript.authoritativeText
                        return text.isEmpty ? nil : text
                    case .error:
                        await client.disconnect()
                        return nil
                    case .completed:
                        await client.disconnect()
                        return nil
                    default:
                        continue
                    }
                }
                await client.disconnect()
                return nil
            } catch {
                DebugFileLogger.log("batch fallback error: \(error)")
                await client.disconnect()
                return nil
            }
        }
        // Hard timeout via withCheckedContinuation (same pattern as withTimeout).
        // If resultTask is stuck in a non-cooperative await, we return nil after 30s.
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let result = await resultTask.value
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(30))
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    resultTask.cancel()
                    DebugFileLogger.log("batch fallback timeout after 30s")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Force Reset

    /// Aggressively tear down all resources and return to idle.
    /// Used when a new recording is requested but the session is stuck
    /// (e.g. stopRecording hung on a WebSocket timeout).
    private func forceReset() async {
        AppLogger.log("[Session] forceReset from state=\(String(describing: state))")
        DebugFileLogger.log("forceReset from state=\(state)")

        eventConsumptionTask?.cancel()
        eventConsumptionTask = nil
        resetSpeculativeLLM()

        audioEngine.stop()
        audioEngine.clearAudioHandlers()
        await finishAudioChunkPipeline(timeout: .milliseconds(100))

        if let client = asrClient {
            Task.detached { await client.disconnect() }  // fire-and-forget: detached to avoid blocking actor
        }
        asrClient = nil

        sessionGeneration &+= 1
        state = .idle
        currentTranscript = .empty
        hasEmittedReadyForCurrentSession = false
        currentConfig = nil
    }

}

#if DEBUG
extension RecognitionSession {
    func handleASREventForTesting(_ event: RecognitionEvent, expectedGeneration: Int? = nil) {
        handleASREvent(event, expectedGeneration: expectedGeneration ?? sessionGeneration)
    }

    var sessionGenerationForTesting: Int {
        sessionGeneration
    }

    var transcriptForTesting: RecognitionTranscript {
        currentTranscript
    }

    var hasEmittedReadyForTesting: Bool {
        hasEmittedReadyForCurrentSession
    }
}
#endif
