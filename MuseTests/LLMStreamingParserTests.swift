import XCTest
@testable import Muse

final class LLMStreamingParserTests: XCTestCase {
    func testDataWithoutSpaceAndDoneAreParsed() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data:{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)
        try parser.consume(line: "")
        try parser.consume(line: "data:[DONE]")

        XCTAssertEqual(try parser.finish(), "你好")
        XCTAssertTrue(parser.isComplete)
    }

    func testDataWithSpaceAndCRLFAreParsed() throws {
        var parser = LLMStreamingParser()
        try parser.consume(
            line: #"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"# + "\r"
        )
        try parser.consume(line: "\r")
        try parser.consume(line: "data: [DONE]" + "\r")

        XCTAssertEqual(try parser.finish(), "hello")
    }

    func testMultilineDataEventIsJoinedBeforeDecoding() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":"#)
        try parser.consume(line: #"data: {"content":"joined"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "joined")
        XCTAssertTrue(parser.isComplete)
    }

    func testNonEmptyFinishReasonCompletesWithoutDone() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"finished"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "finished")
        XCTAssertTrue(parser.isComplete)
    }

    func testFinishReasonWithoutDeltaStillCompletes() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"body"},"finish_reason":null}]}"#)
        try parser.consume(line: "")
        try parser.consume(line: #"data: {"choices":[{"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "body")
        XCTAssertTrue(parser.isComplete)
    }

    func testEmptyFinishReasonDoesNotComplete() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":""}]}"#)
        try parser.consume(line: "")

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case LLMError.truncatedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testConnectionCloseAfterPartialTextIsTruncated() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        XCTAssertThrowsError(try parser.finish()) { error in
            guard case LLMError.truncatedResponse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTransportFailureAfterPartialTextBecomesRetryableTruncatedError() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)

        let error = parser.errorForStreamFailure(URLError(.networkConnectionLost))
        guard case LLMError.truncatedResponse = error else {
            return XCTFail("unexpected error: \(error)")
        }
    }

    func testParserErrorAfterPartialTextIsNotReclassifiedAsTruncated() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        let error = parser.errorForStreamFailure(LLMError.responseTooLarge(5))
        guard case LLMError.responseTooLarge(let maximum) = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(maximum, 5)
    }

    func testCancellationAfterPartialTextPropagatesUnchanged() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        try parser.consume(line: "")

        let error = parser.errorForStreamFailure(CancellationError())
        XCTAssertTrue(error is CancellationError)
    }

    func testResponseLargerThanLimitIsRejectedBeforeAppend() throws {
        var parser = LLMStreamingParser(maxResponseBytes: 5)

        XCTAssertThrowsError(
            try {
                try parser.consume(
                    line: #"data: {"choices":[{"delta":{"content":"123456"},"finish_reason":"stop"}]}"#
                )
                try parser.consume(line: "")
            }()
        ) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMultilineEventEnvelopeHasIndependentHardLimit() throws {
        var parser = LLMStreamingParser(maxResponseBytes: 100, maxEventBytes: 5)
        try parser.consume(line: "data: 123")

        XCTAssertThrowsError(try parser.consume(line: "data: 456")) { error in
            guard case LLMError.responseTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCommentsAndUnknownFieldsAreIgnored() throws {
        var parser = LLMStreamingParser()
        try parser.consume(line: ": keep-alive")
        try parser.consume(line: "event: message")
        try parser.consume(line: #"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#)
        try parser.consume(line: "")

        XCTAssertEqual(try parser.finish(), "ok")
    }
}
