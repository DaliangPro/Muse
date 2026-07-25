import Foundation

enum AliyunASRError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case notConnected
    case taskFailed(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "AliyunASRClient requires AliyunASRConfig"
        case .notConnected:
            return L("阿里云识别服务尚未连接", "Alibaba Cloud ASR is not connected")
        case .taskFailed(let code, let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = detail?.isEmpty == false
                ? detail!
                : L("阿里云识别任务失败", "Alibaba Cloud ASR task failed")
            return code.map { "\(base) (\($0))" } ?? base
        }
    }
}

protocol AliyunWebSocketTasking: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: AliyunWebSocketTasking {}

struct AliyunDialResources: Sendable {
    let task: any AliyunWebSocketTasking
    let invalidateSession: @Sendable () -> Void
}

typealias AliyunDialFactory = @Sendable (
    _ request: URLRequest,
    _ configuration: URLSessionConfiguration
) -> AliyunDialResources

actor AliyunASRClient: WebSocketASRClient {
    private let dialFactory: AliyunDialFactory
    private var webSocketTask: (any AliyunWebSocketTasking)?
    private var invalidateSession: (@Sendable () -> Void)?
    private var connectionID: UUID?
    private var taskID: String?
    private var receiveTask: Task<Void, Never>?
    private var didRequestEndAudio = false
    private var didEmitTerminalEvent = false
    private var audioPacketCount = 0
    private var accumulator = AliyunTranscriptAccumulator()
    private var lastTranscript: RecognitionTranscript = .empty

    var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    var _events: AsyncStream<RecognitionEvent>?

    init(dialFactory: @escaping AliyunDialFactory = { request, configuration in
        let session = URLSession(configuration: configuration)
        return AliyunDialResources(
            task: session.webSocketTask(with: request),
            invalidateSession: { session.invalidateAndCancel() }
        )
    }) {
        self.dialFactory = dialFactory
    }

    func connect(
        config: any ASRProviderConfig,
        options: ASRRequestOptions = ASRRequestOptions()
    ) async throws {
        guard let aliyunConfig = config as? AliyunASRConfig else {
            throw AliyunASRError.unsupportedProvider
        }
        if connectionID != nil || webSocketTask != nil || receiveTask != nil {
            disconnect()
        }

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        didRequestEndAudio = false
        didEmitTerminalEvent = false
        audioPacketCount = 0
        accumulator = AliyunTranscriptAccumulator()
        lastTranscript = .empty

        let newConnectionID = UUID()
        let newTaskID = UUID().uuidString.lowercased()
        var request = URLRequest(url: aliyunConfig.endpoint)
        request.setValue("Bearer \(aliyunConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Muse", forHTTPHeaderField: "User-Agent")
        if let workspaceId = aliyunConfig.workspaceId {
            request.setValue(workspaceId, forHTTPHeaderField: "X-DashScope-WorkSpace")
        }

        let resources = dialFactory(request, options.urlSessionConfiguration)
        let socket = resources.task
        connectionID = newConnectionID
        taskID = newTaskID
        webSocketTask = socket
        invalidateSession = resources.invalidateSession
        socket.resume()

        do {
            let runTask = try AliyunASRProtocol.makeRunTaskMessage(
                taskID: newTaskID,
                config: aliyunConfig,
                options: options
            )
            try await socket.send(.string(runTask))
            let firstMessage = try await socket.receive()
            let firstEvent = try Self.parse(firstMessage)
            try Self.validateTaskStarted(firstEvent, expectedTaskID: newTaskID)
        } catch {
            closeConnection(
                connectionID: newConnectionID,
                closeCode: .abnormalClosure,
                finishEvents: true
            )
            throw error
        }

        guard owns(socket, connectionID: newConnectionID) else {
            throw CancellationError()
        }
        startReceiveLoop(connectionID: newConnectionID, taskID: newTaskID, socket: socket)
        AppLogger.log("[AliyunASR] task started")
    }

    func sendAudio(_ data: Data) async throws {
        guard let socket = webSocketTask,
              let activeConnectionID = connectionID,
              taskID != nil
        else { throw AliyunASRError.notConnected }
        try await socket.send(.data(data))
        guard owns(socket, connectionID: activeConnectionID) else {
            throw CancellationError()
        }
        audioPacketCount += 1
    }

    func endAudio() async throws {
        guard let socket = webSocketTask,
              let taskID
        else { throw AliyunASRError.notConnected }
        didRequestEndAudio = true
        let finishTask = try AliyunASRProtocol.makeFinishTaskMessage(taskID: taskID)
        try await socket.send(.string(finishTask))
        AppLogger.log("[AliyunASR] finish-task sent")
    }

    func disconnect() {
        guard let connectionID else {
            eventContinuation?.finish()
            eventContinuation = nil
            return
        }
        closeConnection(
            connectionID: connectionID,
            closeCode: .normalClosure,
            finishEvents: true
        )
        AppLogger.log("[AliyunASR] disconnected")
    }

    private func startReceiveLoop(
        connectionID: UUID,
        taskID: String,
        socket: any AliyunWebSocketTasking
    ) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self.handleMessage(
                        message,
                        connectionID: connectionID,
                        expectedTaskID: taskID
                    )
                } catch {
                    await self.handleReceiveError(
                        error,
                        connectionID: connectionID,
                        wasCancelled: Task.isCancelled
                    )
                    break
                }
            }
        }
    }

    private func handleMessage(
        _ message: URLSessionWebSocketTask.Message,
        connectionID: UUID,
        expectedTaskID: String
    ) {
        guard self.connectionID == connectionID, !didEmitTerminalEvent else { return }
        do {
            let event = try Self.parse(message)
            switch event {
            case .taskStarted(let taskID):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)

            case .result(let taskID, let sentence):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                guard let transcript = accumulator.apply(sentence), transcript != lastTranscript else {
                    return
                }
                lastTranscript = transcript
                emitEvent(.transcript(transcript))

            case .taskFinished(let taskID):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                let finalTranscript = accumulator.transcript(isFinal: true)
                if finalTranscript != lastTranscript, !finalTranscript.displayText.isEmpty {
                    lastTranscript = finalTranscript
                    emitEvent(.transcript(finalTranscript))
                }
                emitCompletedOnce()
                closeConnection(
                    connectionID: connectionID,
                    closeCode: .normalClosure,
                    finishEvents: false
                )

            case .taskFailed(let taskID, let code, let message):
                try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                emitTerminalError(AliyunASRError.taskFailed(code: code, message: message))
                closeConnection(
                    connectionID: connectionID,
                    closeCode: .protocolError,
                    finishEvents: false
                )

            case .unknown(let taskID, let name):
                if let taskID {
                    try Self.validate(taskID: taskID, expectedTaskID: expectedTaskID)
                }
                AppLogger.log("[AliyunASR] ignored event=\(name)")
            }
        } catch {
            AppLogger.log("[AliyunASR] protocol error: \(String(describing: error))")
            emitTerminalError(error)
            closeConnection(
                connectionID: connectionID,
                closeCode: .protocolError,
                finishEvents: false
            )
        }
    }

    private func handleReceiveError(
        _ error: Error,
        connectionID: UUID,
        wasCancelled: Bool
    ) {
        guard self.connectionID == connectionID,
              !wasCancelled,
              !didEmitTerminalEvent
        else { return }
        AppLogger.log("[AliyunASR] receive error: \(String(describing: error))")
        if didRequestEndAudio || audioPacketCount == 0 {
            emitTerminalError(error)
        } else {
            emitEvent(.streamingInterrupted)
        }
    }

    private func owns(
        _ task: any AliyunWebSocketTasking,
        connectionID expectedConnectionID: UUID
    ) -> Bool {
        guard connectionID == expectedConnectionID,
              let currentTask = webSocketTask
        else { return false }
        return ObjectIdentifier(currentTask) == ObjectIdentifier(task)
    }

    private func closeConnection(
        connectionID expectedConnectionID: UUID,
        closeCode: URLSessionWebSocketTask.CloseCode,
        finishEvents: Bool
    ) {
        guard connectionID == expectedConnectionID else { return }
        let task = webSocketTask
        let invalidate = invalidateSession
        let loop = receiveTask
        connectionID = nil
        taskID = nil
        webSocketTask = nil
        invalidateSession = nil
        receiveTask = nil
        loop?.cancel()
        task?.cancel(with: closeCode, reason: nil)
        invalidate?()
        if finishEvents {
            eventContinuation?.finish()
            eventContinuation = nil
        }
    }

    private func emitCompletedOnce() {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func emitTerminalError(_ error: Error) {
        guard !didEmitTerminalEvent else { return }
        didEmitTerminalEvent = true
        eventContinuation?.yield(.error(error))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) throws -> AliyunServerEvent {
        switch message {
        case .string(let text):
            return try AliyunASRProtocol.parseServerMessage(text)
        case .data(let data):
            guard data.count <= AliyunASRProtocol.maximumServerMessageBytes,
                  let text = String(data: data, encoding: .utf8)
            else { throw AliyunASRProtocolError.invalidMessage }
            return try AliyunASRProtocol.parseServerMessage(text)
        @unknown default:
            throw AliyunASRProtocolError.invalidMessage
        }
    }

    private static func validateTaskStarted(
        _ event: AliyunServerEvent,
        expectedTaskID: String
    ) throws {
        switch event {
        case .taskStarted(let taskID):
            try validate(taskID: taskID, expectedTaskID: expectedTaskID)
        case .taskFailed(_, let code, let message):
            throw AliyunASRError.taskFailed(code: code, message: message)
        case .unknown(_, let name):
            throw AliyunASRProtocolError.unexpectedEvent(name)
        default:
            throw AliyunASRProtocolError.unexpectedEvent("handshake")
        }
    }

    private static func validate(taskID: String, expectedTaskID: String) throws {
        guard taskID == expectedTaskID else {
            throw AliyunASRProtocolError.taskIDMismatch
        }
    }
}
