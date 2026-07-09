import Foundation
import os

/// ASR client that connects to the local SenseVoice Python server via WebSocket.
actor SenseVoiceWSClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "pro.daliang.muse.asr", category: "SenseVoiceWS")

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false

    /// Running text from the server (latest partial or final).
    private var currentText: String = ""
    private var confirmedSegments: [String] = []

    /// Qwen3-only mode: no SenseVoice streaming, just accumulate audio for Qwen3 final.
    private var qwen3OnlyMode = false

    // Qwen3 incremental speculative transcription
    private var qwen3DebounceTask: Task<Void, Never>?
    private var allAudioData: Data = Data()
    private var qwen3ConfirmedOffset: Int = 0
    private var qwen3ConfirmedSegments: [String] = []
    private var qwen3HasPendingAudio: Bool = false

    /// REPAIR_PLAN J10：Qwen3 校准音频缓冲的内存软上限（镜像 B8 采集层的 30 分钟）。
    /// 超限即丢弃整段并停止累积——半截音频做 final 校准会产出错误的半截文本
    /// 覆盖流式结果，比不校准更糟；超长会话的文本由 SenseVoice 流式结果保证。可注入小值供测试。
    var accumulatedAudioByteLimit = 30 * 60 * 16000 * MemoryLayout<Int16>.size
    private var audioAccumulationOverflowed = false

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        // Fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        currentText = ""
        confirmedSegments = []
        resetQwen3State()
        qwen3OnlyMode = false
        didRequestEndAudio = false
        didEmitTerminalEvent = false

        let mgr = SenseVoiceServerManager.shared
        let svPort = SenseVoiceServerManager.currentPort

        if svPort != nil {
            // SenseVoice available: connect WebSocket for streaming
            var healthy = false
            for _ in 0..<30 {
                if await mgr.isHealthy() { healthy = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard healthy else {
                throw SenseVoiceWSError.serverNotHealthy
            }
            guard let url = await mgr.serverWSURL else {
                throw SenseVoiceWSError.serverNotRunning
            }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            task.resume()
            self.session = session
            self.webSocketTask = task

            startReceiveLoop()
            eventContinuation?.yield(.ready)
            logger.info("SenseVoiceWS connected to \(url)")
        } else if SenseVoiceServerManager.currentQwen3Port != nil {
            // Qwen3-only mode: no streaming, just accumulate audio for final
            qwen3OnlyMode = true
            eventContinuation?.yield(.ready)
            logger.info("Qwen3-only mode (no SenseVoice streaming)")
            DebugFileLogger.log("Qwen3-only mode: no streaming, final via Qwen3")
        } else {
            // Neither available
            let svEnabled = UserDefaults.standard.object(forKey: DefaultsKeys.sensevoiceEnabled) as? Bool ?? true
            let q3Enabled = UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true
            if !svEnabled && !q3Enabled {
                throw SenseVoiceWSError.allModelsDisabled
            }
            // At least one is enabled but not started yet, try to start
            try await mgr.start()
            if SenseVoiceServerManager.currentPort == nil && SenseVoiceServerManager.currentQwen3Port == nil {
                throw SenseVoiceWSError.serverNotRunning
            }
            try await connect(config: config, options: options)
            return
        }
    }

    // MARK: - Send Audio

    func sendAudio(_ data: Data) async throws {
        if !qwen3OnlyMode {
            guard let task = webSocketTask else { return }
            try await task.send(.data(data))
        }

        // Accumulate audio for Qwen3 (speculative or final-only)
        // REPAIR_PLAN J10：超上限丢弃整段、停止累积并放弃本会话校准（含在途投机）
        guard !audioAccumulationOverflowed else { return }
        if allAudioData.count + data.count > accumulatedAudioByteLimit {
            audioAccumulationOverflowed = true
            qwen3DebounceTask?.cancel()
            allAudioData = Data()
            qwen3ConfirmedOffset = 0
            qwen3ConfirmedSegments = []
            qwen3HasPendingAudio = false
            DebugFileLogger.log("Qwen3 audio buffer over limit; calibration disabled for this session")
            return
        }
        allAudioData.append(data)
        qwen3HasPendingAudio = true
        if !qwen3OnlyMode {
            scheduleSpeculativeQwen3()
        }
    }

    // MARK: - End Audio

    /// Whether Qwen3 final verification is enabled (user setting).
    private static var isQwen3FinalEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true
    }

    func endAudio() async throws {
        didRequestEndAudio = true
        qwen3DebounceTask?.cancel()

        let qwen3Enabled = Self.isQwen3FinalEnabled || qwen3OnlyMode
        let port = SenseVoiceServerManager.currentQwen3Port
        let task = webSocketTask

        // Qwen3 final: cancel WebSocket, send all audio to Qwen3, use its result
        if qwen3Enabled, let port, allAudioData.count > 3200 {
            let newAudioBytes = allAudioData.count - qwen3ConfirmedOffset
            let hasQwen3Result = !qwen3ConfirmedSegments.isEmpty
            let newAudioTrivial = newAudioBytes < 2 * 16000 * 2

            let finalText: String
            if hasQwen3Result && newAudioTrivial {
                // Speculative covered most audio, just handle the tail
                var assembled = qwen3ConfirmedSegments.joined()
                if newAudioBytes > 3200 {
                    if let tailText = await qwen3Transcribe(audio: Data(allAudioData.suffix(from: qwen3ConfirmedOffset)), port: port, timeout: 10) {
                        assembled += tailText
                    }
                }
                finalText = assembled
                DebugFileLogger.log("Qwen3 final: incremental (\(qwen3ConfirmedSegments.count) segments + tail)")
            } else {
                // No speculative, send full audio
                DebugFileLogger.log("Qwen3 full final: sending \(allAudioData.count) bytes")
                finalText = await qwen3Transcribe(audio: Data(allAudioData), port: port, timeout: 30) ?? ""
                DebugFileLogger.log("Qwen3 full final: \(finalText.count) chars")
            }

            // Cancel SenseVoice WebSocket if connected (don't let its final propagate)
            task?.cancel(with: .normalClosure, reason: nil)

            if !finalText.isEmpty {
                confirmedSegments = [finalText]
                currentText = ""
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: finalText,
                    isFinal: true
                )
                eventContinuation?.yield(.transcript(transcript))
                emitCompletedOnce()
            } else {
                // Qwen3 failed, emit whatever SenseVoice had as final
                let fallback = (confirmedSegments + (currentText.isEmpty ? [] : [currentText])).joined()
                DebugFileLogger.log("Qwen3 final failed, using SenseVoice fallback: \(fallback.count) chars")
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: fallback,
                    isFinal: true
                )
                eventContinuation?.yield(.transcript(transcript))
                emitCompletedOnce()
            }
        } else if let task {
            // Qwen3 disabled: SenseVoice final via WebSocket
            try await task.send(.data(Data()))
            DebugFileLogger.log("SenseVoice final (Qwen3 disabled)")
        } else {
            // No WebSocket and no Qwen3 - nothing to do
            DebugFileLogger.log("endAudio: no WebSocket and no Qwen3 port")
            emitCompletedOnce()
        }

        resetQwen3State()
    }

    /// POST audio to Qwen3 /transcribe and return text, or nil on failure.
    private func qwen3Transcribe(audio: Data, port: Int, timeout: TimeInterval) async -> String? {
        let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Qwen3 Speculative

    private func scheduleSpeculativeQwen3() {
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard await self.qwen3HasPendingAudio else { return }
            guard let port = SenseVoiceServerManager.currentQwen3Port else { return }

            // Take a single consistent snapshot: the delta slice and the offset
            // it ends at are computed in one actor hop, so the region we send to
            // Qwen3 and the region we later mark as confirmed are identical even
            // if sendAudio appends more audio during the HTTP round-trip.
            let snapshot = await self.snapshotQwen3Delta()
            let deltaAudio = snapshot.delta
            let offsetSnapshot = snapshot.endOffset
            guard deltaAudio.count > 3200 else { return }  // at least 100ms of audio

            let url = URL(string: "http://127.0.0.1:\(port)/transcribe")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = deltaAudio
            request.timeoutInterval = 30

            DebugFileLogger.log("Qwen3 speculative: sending \(deltaAudio.count) bytes (offset \(snapshot.start))")

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String, !text.isEmpty {
                    await self.confirmQwen3Segment(text, offset: offsetSnapshot)
                }
            } catch {
                DebugFileLogger.log("Qwen3 speculative: failed \(error)")
            }
        }
    }

    /// Atomically snapshot the unconfirmed audio delta and the offset it ends at.
    /// Reading the start offset and the buffer in one actor-isolated call keeps
    /// `endOffset` (= start + delta.count) exactly aligned with the bytes returned,
    /// so the confirmed offset can only advance by what was actually transcribed.
    private func snapshotQwen3Delta() -> (delta: Data, start: Int, endOffset: Int) {
        // clamp 防御（REPAIR_PLAN J10）：缓冲被超限清空等场景下 offset 可能大于
        // 当前长度，suffix(from:) 越界会直接 precondition crash
        let start = min(qwen3ConfirmedOffset, allAudioData.count)
        let delta = Data(allAudioData.suffix(from: start))
        return (delta, start, start + delta.count)
    }

    private func confirmQwen3Segment(_ text: String, offset: Int) {
        qwen3ConfirmedSegments.append(text)
        qwen3ConfirmedOffset = offset
        qwen3HasPendingAudio = false
        DebugFileLogger.log("Qwen3 speculative: confirmed segment \(qwen3ConfirmedSegments.count): \(text.count) chars")
    }

    private func resetQwen3State() {
        allAudioData = Data()
        qwen3ConfirmedOffset = 0
        qwen3ConfirmedSegments = []
        qwen3HasPendingAudio = false
        audioAccumulationOverflowed = false
    }

    // MARK: - Text Cleaning

    /// Keep only: Chinese (CJK Unified), English letters, digits, spaces
    private static let nonZhEnPattern = try! NSRegularExpression(pattern: #"[^\u4e00-\u9fff\u3400-\u4dbfa-zA-Z0-9 ]"#)

    /// Remove non-Chinese/English characters from streaming partials (e.g. Japanese kana, Korean).
    private static func filterNonZhEn(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return nonZhEnPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Disconnect

    func disconnect() async {
        qwen3DebounceTask?.cancel()
        qwen3DebounceTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        logger.info("SenseVoiceWS disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        self.logger.info("SenseVoiceWS receive loop ended: \(error)")
                        if await self.didRequestEndAudio {
                            await self.emitCompletedOnce()
                        } else {
                            await self.emitEvent(.streamingInterrupted)
                        }
                    }
                    break
                }
            }
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return }

            switch type {
            case "transcript":
                var recognizedText = json["text"] as? String ?? ""
                let isFinal = json["is_final"] as? Bool ?? false

                if !isFinal {
                    // Filter non-Chinese/English characters from streaming partials
                    recognizedText = Self.filterNonZhEn(recognizedText)
                }

                if isFinal {
                    if !recognizedText.isEmpty {
                        confirmedSegments.append(recognizedText)
                    }
                    currentText = ""
                } else {
                    currentText = recognizedText
                }

                let composedText = (confirmedSegments + (currentText.isEmpty ? [] : [currentText])).joined()

                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: isFinal ? "" : currentText,
                    authoritativeText: isFinal ? composedText : "",
                    isFinal: isFinal
                )
                eventContinuation?.yield(.transcript(transcript))

                DebugFileLogger.log("SenseVoiceWS: confirmed=\(confirmedSegments.count) partial=\(currentText.count) composed=\(composedText.count) isFinal=\(isFinal)")

            case "completed":
                if didRequestEndAudio {
                    emitCompletedOnce()
                    logger.info("SenseVoiceWS: server signaled completion")
                } else {
                    emitEvent(.streamingInterrupted)
                    logger.info("SenseVoiceWS: server completed before endAudio")
                }

            case "error":
                let msg = json["message"] as? String ?? "Unknown server error"
                logger.error("SenseVoiceWS server error: \(msg)")
                emitTerminalError(NSError(
                    domain: "SenseVoice", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                ))

            default:
                break
            }

        case .data:
            // We don't expect binary from server
            break

        @unknown default:
            break
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func emitCompletedOnce() {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.completed)
    }

    private func emitTerminalError(_ error: Error) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.error(error))
    }
}

// MARK: - Errors

enum SenseVoiceWSError: Error, LocalizedError {
    case serverNotRunning
    case serverNotHealthy
    case allModelsDisabled

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return L("识别服务未启动", "ASR server not running")
        case .serverNotHealthy:
            return L("识别服务未就绪", "ASR server not ready")
        case .allModelsDisabled:
            return L("请先在设置中启动识别模型", "Please start an ASR model in Settings")
        }
    }
}
