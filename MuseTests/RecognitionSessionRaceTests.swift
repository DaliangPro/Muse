import XCTest
@preconcurrency import AVFoundation
@testable import Muse

final class RecognitionSessionRaceTests: XCTestCase {
    func testOldConnectFailureCannotStopNewSessionAudio() async {
        let first = RaceTestRecognizer(connectMode: .suspended)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let audio = AudioCaptureSpy()
        let session = makeSession(factory: factory, audio: audio)

        let firstStart = Task { await session.startRecording() }
        await waitUntil { await first.isConnecting }

        await session.startRecording()
        let secondIsActive = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActive)
        XCTAssertTrue(audio.isRunning)

        await first.failConnect(TestRaceError.connectFailed)
        await firstStart.value

        XCTAssertTrue(audio.isRunning, "旧会话连接失败不得停止新会话音频")
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.forceResetForTesting()
    }

    func testOldCompletedEventCannotChangeNewSessionState() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(factory: factory)
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)
        await session.startRecording()
        recorder.clear()

        await session.handleASREventForTesting(.completed, expectedSessionID: firstID)

        let state = await session.state
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(recorder.values, [])
        await session.forceResetForTesting()
    }

    func testOldTranscriptCannotReachNewSession() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let recorder = RaceRecognitionEventRecorder()
        let session = makeSession(factory: factory)
        await session.setOnASREvent { recorder.record($0) }

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)
        await session.startRecording()
        recorder.clear()

        await session.handleASREventForTesting(
            .transcript(Self.transcript("旧会话文本")),
            expectedSessionID: firstID
        )

        XCTAssertEqual(recorder.values, [])
        let transcript = await session.transcriptForTesting
        XCTAssertEqual(transcript, .empty)
        await session.forceResetForTesting()
    }

    func testForceResetInvalidatesSessionBeforeDetachedCleanupSuspends() async throws {
        let first = RaceTestRecognizer(connectMode: .immediate, blocksDisconnect: true)
        let factory = RaceRecognizerFactory(preloaded: [first])
        let session = makeSession(factory: factory)

        await session.startRecording()
        let firstIDCandidate = await session.currentSessionIDForTesting
        let firstID = try XCTUnwrap(firstIDCandidate)

        await session.forceResetForTesting()
        await waitUntil { await first.isDisconnecting }

        let currentID = await session.currentSessionIDForTesting
        XCTAssertNotEqual(currentID, firstID)
        XCTAssertNil(currentID)
        let state = await session.state
        XCTAssertEqual(state, .idle)
        let firstIsActive = await session.isActiveClientForTesting(first)
        XCTAssertFalse(firstIsActive)

        await first.releaseDisconnect()
    }

    func testRapidStartStopStartInterleavingLeavesOneActiveClient() async {
        let factory = RaceRecognizerFactory()
        let session = makeSession(factory: factory)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    switch index % 3 {
                    case 0, 2:
                        await session.startRecording()
                    default:
                        await session.stopRecording()
                    }
                }
            }
        }

        // 把最终意图固定为 start；前面的 100 次只负责制造交错。
        await session.startRecording()
        await waitUntil {
            await factory.undisconnectedClientCount == 1
        }

        let state = await session.state
        let activeClientCount = await session.activeClientCountForTesting
        let undisconnectedClientCount = await factory.undisconnectedClientCount
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(activeClientCount, 1)
        XCTAssertEqual(undisconnectedClientCount, 1)
        await session.forceResetForTesting()
    }

    func testLateOldClientDisconnectCannotClearNewClient() async {
        let first = RaceTestRecognizer(connectMode: .immediate, blocksDisconnect: true)
        let second = RaceTestRecognizer(connectMode: .immediate)
        let factory = RaceRecognizerFactory(preloaded: [first, second])
        let session = makeSession(factory: factory)

        await session.startRecording()
        let firstStop = Task { await session.stopRecording() }
        await waitUntil { await first.isDisconnecting }

        await session.startRecording()

        let secondIsActiveBefore = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActiveBefore)
        await first.releaseDisconnect()
        await firstStop.value
        await waitUntil { await first.isDisconnected }

        let secondIsActiveAfter = await session.isActiveClientForTesting(second)
        XCTAssertTrue(secondIsActiveAfter)
        let activeClientCount = await session.activeClientCountForTesting
        XCTAssertEqual(activeClientCount, 1)
        await session.forceResetForTesting()
    }

    func testSecondStopDoesNotDuplicateInjectionOrHistory() async {
        let client = RaceTestRecognizer(
            connectMode: .immediate,
            finalTranscript: "只应写入一次"
        )
        let factory = RaceRecognizerFactory(preloaded: [client])
        let injection = TextInjectionSpy()
        let history = HistoryStore(path: ":memory:")
        let session = makeSession(
            factory: factory,
            injection: injection,
            historyStore: history
        )

        await session.startRecording()
        await session.stopRecording()
        await session.stopRecording()

        XCTAssertEqual(injection.injectionCount, 1)
        let historyCount = await history.count()
        let state = await session.state
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(state, .idle)
    }

    private func makeSession(
        factory: RaceRecognizerFactory,
        audio: AudioCaptureSpy = AudioCaptureSpy(),
        injection: TextInjectionSpy = TextInjectionSpy(),
        historyStore: HistoryStore = HistoryStore(path: ":memory:")
    ) -> RecognitionSession {
        RecognitionSession(
            audioEngine: audio,
            injectionEngine: injection,
            historyStore: historyStore,
            asrClientFactory: { factory.makeClient(for: $0) },
            selectedASRProvider: { .apple },
            asrConfigLoader: { _ in AppleASRConfig(credentials: [:]) },
            microphonePermission: { true },
            promptContextCapture: {
                PromptContext(selectedText: "", clipboardText: "")
            },
            requestOptionsProvider: { _ in (ASRRequestOptions(), 0) }
        )
    }

    fileprivate static func transcript(_ text: String) -> RecognitionTranscript {
        RecognitionTranscript(
            confirmedSegments: [text],
            partialText: "",
            authoritativeText: text,
            isFinal: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待异步条件超时")
    }
}

private enum TestRaceError: Error {
    case connectFailed
}

private actor RaceTestRecognizer: SpeechRecognizer {
    enum ConnectMode: Sendable, Equatable {
        case immediate
        case suspended
    }

    private let eventStream: AsyncStream<RecognitionEvent>
    private let eventContinuation: AsyncStream<RecognitionEvent>.Continuation
    private let connectMode: ConnectMode
    private let finalTranscript: String?
    private let blocksDisconnect: Bool
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleased = false
    private(set) var isConnecting = false
    private(set) var isDisconnecting = false
    private(set) var isDisconnected = false

    init(
        connectMode: ConnectMode,
        finalTranscript: String? = nil,
        blocksDisconnect: Bool = false
    ) {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
        self.connectMode = connectMode
        self.finalTranscript = finalTranscript
        self.blocksDisconnect = blocksDisconnect
    }

    var events: AsyncStream<RecognitionEvent> {
        eventStream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        _ = config
        _ = options
        guard connectMode == .suspended else { return }
        try await withCheckedThrowingContinuation { continuation in
            isConnecting = true
            connectContinuation = continuation
        }
    }

    func failConnect(_ error: Error) {
        isConnecting = false
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    func sendAudio(_ data: Data) async throws {
        _ = data
    }

    nonisolated func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }

    func endAudio() async throws {
        if let finalTranscript {
            eventContinuation.yield(.transcript(RecognitionSessionRaceTests.transcript(finalTranscript)))
        }
        eventContinuation.yield(.completed)
        eventContinuation.finish()
    }

    func disconnect() async {
        isDisconnecting = true
        if blocksDisconnect, !disconnectReleased {
            await withCheckedContinuation { continuation in
                disconnectContinuations.append(continuation)
            }
        }
        guard !isDisconnected else { return }
        isDisconnected = true
        eventContinuation.finish()
    }

    func releaseDisconnect() {
        disconnectReleased = true
        let continuations = disconnectContinuations
        disconnectContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class RaceRecognizerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var preloaded: [RaceTestRecognizer]
    private var created: [RaceTestRecognizer] = []

    init(preloaded: [RaceTestRecognizer] = []) {
        self.preloaded = preloaded
    }

    func makeClient(for provider: ASRProvider) -> any SpeechRecognizer {
        _ = provider
        return lock.withLock {
            let client = preloaded.isEmpty
                ? RaceTestRecognizer(connectMode: .immediate)
                : preloaded.removeFirst()
            created.append(client)
            return client
        }
    }

    var undisconnectedClientCount: Int {
        get async {
            let clients = lock.withLock { created }
            var count = 0
            for client in clients where !(await client.isDisconnected) {
                count += 1
            }
            return count
        }
    }
}

private final class AudioCaptureSpy: AudioCaptureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var onChunk: ((Data) -> Void)?
    private var onLevel: ((Float) -> Void)?

    var isRunning: Bool {
        lock.withLock { running }
    }

    func warmUp() {}

    func setAudioHandlers(
        onChunk: ((Data) -> Void)?,
        onLevel: ((Float) -> Void)?
    ) {
        lock.withLock {
            self.onChunk = onChunk
            self.onLevel = onLevel
        }
    }

    func setAudioChunkHandler(_ handler: ((Data) -> Void)?) {
        lock.withLock { onChunk = handler }
    }

    func clearAudioHandlers() {
        setAudioHandlers(onChunk: nil, onLevel: nil)
    }

    func start(timeout: Duration) async throws {
        _ = timeout
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        clearAudioHandlers()
    }

    func getRecordedAudio() -> Data {
        Data()
    }
}

private final class TextInjectionSpy: TextInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreserveClipboard = true
    private var storedInjectionCount = 0

    var preserveClipboard: Bool {
        get { lock.withLock { storedPreserveClipboard } }
        set { lock.withLock { storedPreserveClipboard = newValue } }
    }

    var injectionCount: Int {
        lock.withLock { storedInjectionCount }
    }

    func inject(_ text: String) -> InjectionOutcome {
        _ = text
        lock.withLock { storedInjectionCount += 1 }
        return .inserted
    }
}

private final class RaceRecognitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func clear() {
        lock.withLock { storage.removeAll() }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            switch event {
            case .ready:
                storage.append("ready")
            case .transcript(let transcript):
                storage.append("transcript:\(transcript.displayText)")
            case .error(let error):
                storage.append("error:\(error.localizedDescription)")
            case .completed:
                storage.append("completed")
            case .processingResult(let text):
                storage.append("processing:\(text)")
            case .finalized(let text, let injection):
                storage.append("finalized:\(text):\(injection)")
            case .streamingInterrupted:
                storage.append("streamingInterrupted")
            }
        }
    }
}
