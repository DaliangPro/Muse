import XCTest
@preconcurrency import AVFoundation
@testable import Muse

final class AppleASRClientLifecycleTests: XCTestCase {
    func testEndAudioTimeoutReturnsWithinInjectedDeadline() async throws {
        let recognition = AppleRecognitionSessionSpy()
        let client = makeClient(
            sessions: [recognition],
            timeout: .milliseconds(30)
        )

        try await connect(client)
        let startedAt = ContinuousClock.now
        try await client.endAudio()
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertLessThan(elapsed, .milliseconds(500))
        let cancellationStarted = await waitUntil { recognition.cancelCount == 1 }
        XCTAssertTrue(cancellationStarted)
        await client.disconnect()
    }

    func testOldCallbackAfterNewConnectDoesNotProduceTranscript() async throws {
        let first = AppleRecognitionSessionSpy()
        let second = AppleRecognitionSessionSpy()
        let client = makeClient(sessions: [first, second])
        let recorder = AppleEventRecorder()

        try await connect(client)
        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let readyArrived = await waitUntil { await recorder.contains("ready") }
        XCTAssertTrue(readyArrived)

        first.emit(text: "旧会话文本", isFinal: false)
        try? await Task.sleep(for: .milliseconds(50))

        let values = await recorder.values
        XCTAssertFalse(values.contains("transcript:旧会话文本:false"))
        await client.disconnect()
        await consumer.value
    }

    func testOldErrorDoesNotFinishNewStream() async throws {
        let first = AppleRecognitionSessionSpy()
        let second = AppleRecognitionSessionSpy()
        let client = makeClient(sessions: [first, second])
        let recorder = AppleEventRecorder()

        try await connect(client)
        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        let readyArrived = await waitUntil { await recorder.contains("ready") }
        XCTAssertTrue(readyArrived)

        first.emit(error: AppleLifecycleTestError.oldSession)
        try? await Task.sleep(for: .milliseconds(50))

        let values = await recorder.values
        let prematurelyFinished = await recorder.isFinished
        XCTAssertFalse(values.contains("error:oldSession"))
        XCTAssertFalse(values.contains("completed"))
        XCTAssertFalse(prematurelyFinished)
        await client.disconnect()
        await consumer.value
    }

    func testTimeoutFallbackUsesLatestTranscript() async throws {
        let recognition = AppleRecognitionSessionSpy()
        let client = makeClient(
            sessions: [recognition],
            timeout: .milliseconds(30)
        )
        let recorder = AppleEventRecorder()

        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }
        recognition.emit(text: "当前最新文本", isFinal: false)
        let partialArrived = await waitUntil {
            await recorder.contains("transcript:当前最新文本:false")
        }
        XCTAssertTrue(partialArrived)

        try await client.endAudio()
        let streamFinished = await waitUntil { await recorder.isFinished }
        XCTAssertTrue(streamFinished)
        await consumer.value

        let values = await recorder.values
        XCTAssertTrue(values.contains("transcript:当前最新文本:true"))
        XCTAssertEqual(values.filter { $0 == "completed" }.count, 1)
        await client.disconnect()
    }

    func testDisconnectResumesEndAudioWaiterAndClearsContinuation() async throws {
        let recognition = AppleRecognitionSessionSpy()
        let client = makeClient(
            sessions: [recognition],
            timeout: .seconds(30)
        )

        try await connect(client)
        let endTask = Task { try await client.endAudio() }
        let waiterInstalled = await waitUntil {
            await client.hasFinishWaiterForTesting
        }
        XCTAssertTrue(waiterInstalled)

        await client.disconnect()
        let returned = await AsyncTimeout.run(.seconds(1)) {
            _ = try? await endTask.value
        }

        XCTAssertTrue(returned)
        let hasWaiter = await client.hasFinishWaiterForTesting
        XCTAssertFalse(hasWaiter)
        XCTAssertEqual(recognition.cancelCount, 1)
    }

    func testCompletedIsEmittedOnlyOnce() async throws {
        let recognition = AppleRecognitionSessionSpy()
        let client = makeClient(sessions: [recognition])
        let recorder = AppleEventRecorder()

        try await connect(client)
        let stream = await client.events
        let consumer = Task { await recorder.consume(stream) }

        recognition.emit(text: "最终文本", isFinal: true)
        let streamFinished = await waitUntil { await recorder.isFinished }
        XCTAssertTrue(streamFinished)
        recognition.emit(text: "迟到最终文本", isFinal: true)
        recognition.emit(error: AppleLifecycleTestError.lateTerminal)
        await consumer.value

        let values = await recorder.values
        XCTAssertEqual(values.filter { $0 == "completed" }.count, 1)
        XCTAssertEqual(values.filter { $0.hasPrefix("error:") }.count, 0)
        await client.disconnect()
    }

    private func makeClient(
        sessions: [AppleRecognitionSessionSpy],
        timeout: Duration = .seconds(5)
    ) -> AppleASRClient {
        let factory = AppleRecognitionSessionFactorySpy(sessions: sessions)
        return AppleASRClient(
            permissionProvider: { true },
            recognitionSessionFactory: { _, callback in
                factory.make(callback: callback)
            },
            endAudioTimeout: timeout
        )
    }

    private func connect(_ client: AppleASRClient) async throws {
        let config = try XCTUnwrap(AppleASRConfig(credentials: [:]))
        try await client.connect(config: config, options: ASRRequestOptions())
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let asyncCondition: @Sendable () async -> Bool = { condition() }
        return await waitUntil(timeout: timeout, condition: asyncCondition)
    }
}

private enum AppleLifecycleTestError: Error {
    case oldSession
    case lateTerminal
}

private final class AppleRecognitionSessionFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [AppleRecognitionSessionSpy]

    init(sessions: [AppleRecognitionSessionSpy]) {
        self.sessions = sessions
    }

    func make(
        callback: @escaping @Sendable (AppleRecognitionCallback) -> Void
    ) -> (any AppleRecognitionSessionControlling)? {
        lock.withLock {
            guard !sessions.isEmpty else { return nil }
            let session = sessions.removeFirst()
            session.install(callback: callback)
            return session
        }
    }
}

private final class AppleRecognitionSessionSpy: AppleRecognitionSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (AppleRecognitionCallback) -> Void)?
    private var storedCancelCount = 0

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    func install(callback: @escaping @Sendable (AppleRecognitionCallback) -> Void) {
        lock.withLock { self.callback = callback }
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        _ = buffer
    }

    func endAudio() async {}

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
    }

    func emit(
        text: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) {
        let callback = lock.withLock { self.callback }
        callback?(AppleRecognitionCallback(
            text: text,
            isFinal: isFinal,
            error: error
        ))
    }
}

private actor AppleEventRecorder {
    private(set) var values: [String] = []
    private(set) var isFinished = false

    func consume(_ stream: AsyncStream<RecognitionEvent>) async {
        for await event in stream {
            values.append(Self.describe(event))
        }
        isFinished = true
    }

    func contains(_ value: String) -> Bool {
        values.contains(value)
    }

    private static func describe(_ event: RecognitionEvent) -> String {
        switch event {
        case .ready:
            return "ready"
        case .transcript(let transcript):
            return "transcript:\(transcript.displayText):\(transcript.isFinal)"
        case .error(let error):
            return "error:\(error)"
        case .completed:
            return "completed"
        case .processingResult(let text):
            return "processing:\(text)"
        case .finalized(let text, _):
            return "finalized:\(text)"
        case .streamingInterrupted:
            return "streamingInterrupted"
        }
    }
}
