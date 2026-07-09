import XCTest
import AVFoundation
@testable import Muse

final class AudioCaptureEngineTests: XCTestCase {

    func testAudioChunkSize() {
        XCTAssertEqual(AudioCaptureEngine.chunkByteSize, 6400)
    }

    func testSamplesPerChunk() {
        XCTAssertEqual(AudioCaptureEngine.samplesPerChunk, 3200)
    }

    func testTargetAudioFormat() {
        let format = AudioCaptureEngine.targetFormat
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }

    // MARK: - REPAIR_PLAN B8

    func testAccumulatedAudioRespectsByteLimit() {
        let engine = AudioCaptureEngine()
        engine.accumulatedAudioByteLimit = 1000

        engine.ingestForTesting(Data(repeating: 0x01, count: 600))
        XCTAssertEqual(engine.getRecordedAudio().count, 600)

        // 超限后整段缓存被丢弃，且不再累积
        engine.ingestForTesting(Data(repeating: 0x02, count: 600))
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
        engine.ingestForTesting(Data(repeating: 0x03, count: 100))
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
    }

    func testChunkCallbackStillFiresAfterOverflow() {
        let engine = AudioCaptureEngine()
        engine.accumulatedAudioByteLimit = 100
        var received = 0
        engine.setAudioChunkHandler { _ in received += 1 }

        // 远超上限的数据：整段缓存停了，流式切块照常工作
        engine.ingestForTesting(Data(repeating: 0x01, count: AudioCaptureEngine.chunkByteSize * 3))
        XCTAssertEqual(received, 3)
        XCTAssertTrue(engine.getRecordedAudio().isEmpty)
    }

    // MARK: - REPAIR_PLAN J21

    func testStartStateInvalidatesLateStarts() {
        var state = AudioCaptureStartState()

        let first = state.nextToken()
        XCTAssertTrue(state.isCurrent(first))

        state.invalidate()
        XCTAssertFalse(state.isCurrent(first))

        let second = state.nextToken()
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertFalse(state.isCurrent(first))
    }
}
