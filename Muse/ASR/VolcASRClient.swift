import Foundation

enum VolcASRError: Error, LocalizedError {
    case unsupportedProvider
    case serverRejected(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "VolcASRClient requires VolcanoASRConfig"
        case .serverRejected(let code, let message):
            return message ?? "HTTP \(code)"
        }
    }
}

actor VolcASRClient: WebSocketASRClient {

    private static let endpoint =
        URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false

    var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    var _events: AsyncStream<RecognitionEvent>?

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let volcConfig = config as? VolcanoASRConfig else {
            throw VolcASRError.unsupportedProvider
        }

        // Ensure fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream

        // REPAIR_PLAN B7b：保存连接参数供断网静默重连重拨
        savedConfig = volcConfig
        savedOptions = options
        carriedSegments = []
        didAttemptReconnect = false
        didRequestEndAudio = false
        didEmitTerminalEvent = false

        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil

        try await dial(config: volcConfig, options: options)
    }

    /// 拨号 + 握手 + 启动接收循环（connect 与重连共用；不触碰事件流与计数状态）
    private func dial(config volcConfig: VolcanoASRConfig, options: ASRRequestOptions) async throws {
        let connectId = UUID().uuidString

        var request = URLRequest(url: Self.endpoint)
        request.setValue(volcConfig.appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(volcConfig.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(volcConfig.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: options.urlSessionConfiguration)
        let task = session.webSocketTask(with: request)
        task.resume()
        self.session = session
        self.webSocketTask = task

        // Send full_client_request (no compression, plain JSON)
        let payload = VolcProtocol.buildClientRequest(uid: volcConfig.uid, options: options)

        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)

        AppLogger.log("[ASR] Sending full_client_request (\(message.count) bytes), connectId=\(connectId)")
        do {
            try await task.send(.data(message))
        } catch {
            // WebSocket handshake failed — probe with HTTP to get the real error
            AppLogger.log("[ASR] WebSocket send failed: \(String(describing: error)), probing for server error...")
            if let serverError = await Self.probeServerError(request: request) {
                throw serverError
            }
            throw error
        }

        AppLogger.log("[ASR] full_client_request sent OK")

        // Start receive loop
        startReceiveLoop()
    }

    /// When WebSocket handshake is rejected, make a plain HTTPS request to get the actual error body.
    private static func probeServerError(request: URLRequest) async -> VolcASRError? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        guard let httpsURL = components.url else { return nil }

        var httpRequest = URLRequest(url: httpsURL, timeoutInterval: 5)
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode != 200 else { return nil }

            // Try to parse JSON error body (e.g. {"code": 1001, "message": "..."})
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["message"] as? String ?? json["msg"] as? String
                if let code = json["code"] as? Int, let msg = message {
                    message = "\(msg) (\(code))"
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }

            // 探测回音过滤（2026-07 修）：本探测是普通 HTTP 打到 ws 端点，服务器回
            // "cannot upgrade to websocket / 'upgrade' token not found" 只说明端点活着，
            // 不是对我们业务的拒绝理由——这类裸文只进日志，不糊给用户
            if let text = message?.lowercased(),
               text.contains("websocket") || text.contains("upgrade") {
                AppLogger.log("[ASR] HTTP probe echo (ws endpoint alive), body suppressed: \(message ?? "")")
                message = nil
            }

            AppLogger.log("[ASR] HTTP probe got \(httpResponse.statusCode) bodyBytes=\(data.count)")
            return .serverRejected(statusCode: httpResponse.statusCode, message: message)
        } catch {
            AppLogger.log("[ASR] HTTP probe failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Send Audio

    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var lastTranscript: RecognitionTranscript = .empty
    private var lastTranscriptTime: ContinuousClock.Instant?
    private var sessionStartTime: ContinuousClock.Instant?

    // REPAIR_PLAN B7b：断网静默重连（每会话一次）
    private var savedConfig: VolcanoASRConfig?
    private var savedOptions: ASRRequestOptions?
    /// 重连前冻结的已确认文本，重连后前缀拼接保持字幕连续
    private var carriedSegments: [String] = []
    private var didAttemptReconnect = false

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: data,
            isLast: false
        )
        do {
            try await task.send(.data(packet))
        } catch {
            // REPAIR_PLAN B7b：发送失败先尝试一次静默重连再重发本包；
            // 重连失败则抛出原错误，走既有失败路径（批量兜底）
            guard !didAttemptReconnect else { throw error }
            didAttemptReconnect = true
            try await reconnectOnce(afterError: error)
            guard let newTask = webSocketTask else { throw error }
            try await newTask.send(.data(packet))
            // 告知会话层本次流式已降级：停止后仍需批量复核全文
            // （断线到重连之间的语音服务端没听到，实时字幕只是显示连续）
            emitEvent(.streamingInterrupted)
        }
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    /// 重拨一次：冻结已确认文本 → 撤旧连接 → 重新握手。失败抛出原错误
    private func reconnectOnce(afterError underlying: Error) async throws {
        AppLogger.log("[ASR] 连接中断，尝试静默重连…")
        carriedSegments = lastTranscript.confirmedSegments
            + (lastTranscript.partialText.isEmpty ? [] : [lastTranscript.partialText])
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        guard let config = savedConfig, let options = savedOptions else { throw underlying }
        do {
            try await dial(config: config, options: options)
            AppLogger.log("[ASR] 静默重连成功，已冻结 \(carriedSegments.count) 段前缀")
        } catch {
            AppLogger.log("[ASR] 静默重连失败: \(String(describing: error))")
            throw underlying
        }
    }

    // MARK: - End Audio

    func endAudio() async throws {
        didRequestEndAudio = true
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: Data(),
            isLast: true
        )
        try await task.send(.data(packet))
        AppLogger.log("[ASR] Sent last audio packet (empty, isLast=true)")
    }

    // MARK: - Disconnect

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        AppLogger.log("[ASR] Disconnected")
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
                    AppLogger.log("[ASR] Receive loop error: \(String(describing: error))")
                    if !Task.isCancelled {
                        if await self.didRequestEndAudio {
                            await self.emitCompletedOnce()
                        } else if await self.audioPacketCount == 0 {
                            // No audio sent yet — real connection/auth error.
                            await self.emitTerminalError(error)
                        } else {
                            AppLogger.log("[ASR] Receive loop interrupted while recording (sent \(await self.audioPacketCount) packets)")
                            await self.emitEvent(.streamingInterrupted)
                        }
                    }
                    break
                }
            }
            AppLogger.log("[ASR] Receive loop ended")
            // Finish the event stream so consumers (eventConsumptionTask) can complete.
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            let headerByte1 = data.count > 1 ? data[1] : 0
            let msgType = (headerByte1 >> 4) & 0x0F

            // Server error (0xF): could be a real error or just
            // bigmodel_async's "session complete" signal.
            if msgType == 0x0F {
                if didRequestEndAudio {
                    AppLogger.log("[ASR] Session ended by server after endAudio (\(audioPacketCount) audio packets)")
                    emitCompletedOnce()
                } else if audioPacketCount == 0 {
                    // No audio was sent yet — this is a real setup/auth error.
                    do {
                        _ = try VolcProtocol.decodeServerResponse(data)
                    } catch {
                        AppLogger.log("[ASR] Server error: \(String(describing: error))")
                        emitTerminalError(error)
                    }
                } else {
                    AppLogger.log("[ASR] Server closed stream before endAudio after \(audioPacketCount) packets")
                    emitEvent(.streamingInterrupted)
                }
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
                return
            }

            do {
                let response = try VolcProtocol.decodeServerResponse(data)
                let transcript = makeTranscript(
                    from: response.result,
                    isFinal: response.header.flags == .asyncFinal
                )
                guard transcript != lastTranscript else { return }
                lastTranscript = transcript

                let now = ContinuousClock.now
                let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
                let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
                lastTranscriptTime = now

                let gapMs = Int(sinceLastUpdate.components.seconds * 1000 + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)
                DebugFileLogger.log("ASR transcript +\(sinceStart) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal)")

                AppLogger.log("[ASR] Transcript update +\(String(describing: sinceStart)) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal ? "yes" : "no")")
                emitEvent(.transcript(transcript))

                if transcript.isFinal, !transcript.authoritativeText.isEmpty {
                    AppLogger.log("[ASR] Final transcript len=\(transcript.authoritativeText.count)")
                }
            } catch {
                AppLogger.log("[ASR] Decode error: \(String(describing: error))")
                emitTerminalError(error)
            }

        case .string(let text):
            AppLogger.log("[ASR] Unexpected text message bytes=\(text.utf8.count)")

        @unknown default:
            break
        }
    }


    private func makeTranscript(from result: VolcASRResult, isFinal: Bool) -> RecognitionTranscript {
        Self.transcript(from: result, isFinal: isFinal, carriedSegments: carriedSegments)
    }

    private func emitCompletedOnce() {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        emitEvent(.completed)
    }

    private func emitTerminalError(_ error: Error) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        emitEvent(.error(error))
    }

    /// 纯函数：服务端结果 + 重连前冻结前缀 → 统一转写（REPAIR_PLAN B7b，可单测）
    static func transcript(
        from result: VolcASRResult,
        isFinal: Bool,
        carriedSegments: [String]
    ) -> RecognitionTranscript {
        let confirmedSegments = carriedSegments + result.utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let partialText = result.utterances.last(where: { !$0.definite && !$0.text.isEmpty })?.text ?? ""
        let composedText = (confirmedSegments + (partialText.isEmpty ? [] : [partialText])).joined()
        let authoritativeText = result.text.isEmpty
            ? composedText
            : carriedSegments.joined() + result.text
        return RecognitionTranscript(
            confirmedSegments: confirmedSegments,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
    }
}
