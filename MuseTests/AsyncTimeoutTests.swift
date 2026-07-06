import XCTest
@testable import Muse

final class AsyncTimeoutTests: XCTestCase {
    func testRunReturnsTrueWhenOperationCompletesBeforeDeadline() async {
        let completed = await AsyncTimeout.run(.milliseconds(200)) {}

        XCTAssertTrue(completed)
    }

    func testRunReturnsFalseWhenOperationTimesOut() async {
        let completed = await AsyncTimeout.run(.milliseconds(10)) {
            try await Task.sleep(for: .milliseconds(200))
        }

        XCTAssertFalse(completed)
    }

    func testValueReportsLoadedValue() async {
        let result: TimedValue<String> = await AsyncTimeout.value(.milliseconds(200)) {
            "loaded"
        }

        XCTAssertEqual(result.value, "loaded")
        XCTAssertFalse(result.timedOut)
    }

    func testValueReportsTimeout() async {
        let result: TimedValue<String> = await AsyncTimeout.value(.milliseconds(10)) {
            Thread.sleep(forTimeInterval: 0.2)
            return "late"
        }

        XCTAssertNil(result.value)
        XCTAssertTrue(result.timedOut)
    }
}
