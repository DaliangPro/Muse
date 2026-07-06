import Foundation
import os

/// Thread-safe flag for the detached sender to signal upload failure.
private final class UploadFailureFlag: Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: false)

    var failed: Bool {
        get { _value.withLock { $0 } }
        set { _value.withLock { $0 = newValue } }
    }
}

/// Sends recorded audio chunks to the active ASR client without hopping back to
/// RecognitionSession's actor on every callback.
final class AudioChunkUploadPipeline: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let senderTask: Task<Void, Never>
    private let failureFlag: UploadFailureFlag

    var failed: Bool { failureFlag.failed }

    init(
        client: (any SpeechRecognizer)?,
        audioInput: ASRAudioInputKind,
        emitInterrupted: (@Sendable (RecognitionEvent) -> Void)?
    ) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let failureFlag = UploadFailureFlag()

        self.continuation = continuation
        self.failureFlag = failureFlag
        self.senderTask = Task.detached {
            var chunkCount = 0
            var lastLogTime: ContinuousClock.Instant?

            for await data in stream {
                guard let client else { break }
                let t0 = ContinuousClock.now

                do {
                    switch audioInput {
                    case .pcmData:
                        try await client.sendAudio(data)
                    case .pcmBuffer:
                        guard let buffer = AudioCaptureEngine.makePCMBuffer(from: data) else { continue }
                        try await client.sendAudioBuffer(buffer)
                    }
                } catch {
                    DebugFileLogger.log("audio chunk send failed: \(error)")
                    failureFlag.failed = true
                    emitInterrupted?(.streamingInterrupted)
                    break
                }

                let elapsed = ContinuousClock.now - t0
                chunkCount += 1
                let shouldLog = chunkCount % 50 == 0
                    || elapsed > .milliseconds(200)
                    || lastLogTime == nil
                if shouldLog {
                    DebugFileLogger.log("audio chunk #\(chunkCount) sent \(data.count)B in \(elapsed)")
                    lastLogTime = ContinuousClock.now
                }
            }
        }
    }

    func yield(_ data: Data) {
        guard !failed else { return }
        continuation.yield(data)
    }

    func finish(timeout: Duration = .seconds(1)) async -> Bool {
        continuation.finish()

        let drained = await AsyncTimeout.run(timeout) {
            await self.senderTask.value
        }
        if !drained {
            senderTask.cancel()
            DebugFileLogger.log("audio chunk pipeline drain timeout; sender cancelled")
        }
        return failed
    }

    func cancel() {
        continuation.finish()
        senderTask.cancel()
    }
}
