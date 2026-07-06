import XCTest
@testable import Muse

final class AudioChunkUploadPipelineTests: XCTestCase {
    func testFinishDrainsPCMDataInOrder() async {
        let client = PipelineSpeechRecognizerSpy()
        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: .pcmData,
            emitInterrupted: nil
        )
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])

        pipeline.yield(first)
        pipeline.yield(second)
        let failed = await pipeline.finish(timeout: .seconds(1))

        let sentAudio = await client.sentAudioData()
        XCTAssertEqual(sentAudio, [first, second])
        XCTAssertFalse(failed)
        XCTAssertFalse(pipeline.failed)
    }

    func testSendFailureMarksPipelineFailedAndEmitsInterrupted() async {
        let client = PipelineSpeechRecognizerSpy()
        let recorder = PipelineEventRecorder()
        await client.setSendError(PipelineSendError.intentionalFailure)

        let pipeline = AudioChunkUploadPipeline(
            client: client,
            audioInput: .pcmData,
            emitInterrupted: { recorder.record($0) }
        )

        pipeline.yield(Data([1]))
        let failed = await pipeline.finish(timeout: .seconds(1))

        XCTAssertTrue(failed)
        XCTAssertTrue(pipeline.failed)
        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
    }
}

private enum PipelineSendError: Error {
    case intentionalFailure
}

private actor PipelineSpeechRecognizerSpy: SpeechRecognizer {
    private var audioData: [Data] = []
    private var sendError: Error?

    func setSendError(_ error: Error?) {
        sendError = error
    }

    func sentAudioData() -> [Data] {
        audioData
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}

    func sendAudio(_ data: Data) async throws {
        if let sendError {
            throw sendError
        }
        audioData.append(data)
    }

    func endAudio() async throws {}

    func disconnect() async {}

    var events: AsyncStream<RecognitionEvent> {
        get async {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
    }
}

private final class PipelineEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            switch event {
            case .streamingInterrupted:
                storage.append("streamingInterrupted")
            default:
                storage.append("other")
            }
        }
    }
}
