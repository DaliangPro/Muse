import XCTest
@testable import Muse

/// REPAIR_PLAN H1 遗留①：提炼响应坏 JSON 自动重试一次
final class AssetExtractionRetryTests: XCTestCase {

    private final class MockLLMClient: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String]
        private(set) var callCount = 0
        private(set) var lastPrompt = ""

        init(responses: [String]) { self.responses = responses }

        func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
            lock.withLock {
                callCount += 1
                lastPrompt = prompt
                return responses.isEmpty ? "" : responses.removeFirst()
            }
        }

        func warmUp(baseURL: String) async {}
    }

    private let dummyConfig = LLMConfig(apiKey: "", model: "test", baseURL: "")

    func testValidJSONSucceedsWithoutRetry() async throws {
        let mock = MockLLMClient(responses: ["{}"])
        let provider = RemoteAssetExtractionProvider(clientOverride: mock)
        _ = try await provider.requestAndParse(
            client: mock, input: "记录", prompt: "提示", config: dummyConfig)
        XCTAssertEqual(mock.callCount, 1)
    }

    func testBadJSONRetriesOnceWithCorrectionAndSucceeds() async throws {
        let mock = MockLLMClient(responses: ["对不起，我无法输出 JSON", "{}"])
        let provider = RemoteAssetExtractionProvider(clientOverride: mock)
        _ = try await provider.requestAndParse(
            client: mock, input: "记录", prompt: "提示", config: dummyConfig)
        XCTAssertEqual(mock.callCount, 2)
        XCTAssertTrue(mock.lastPrompt.contains("不是合法 JSON"), "重试应带纠错指令")
    }

    func testBadJSONTwiceThrows() async {
        let mock = MockLLMClient(responses: ["不是JSON", "还不是JSON"])
        let provider = RemoteAssetExtractionProvider(clientOverride: mock)
        do {
            _ = try await provider.requestAndParse(
                client: mock, input: "记录", prompt: "提示", config: dummyConfig)
            XCTFail("两次坏 JSON 应抛错")
        } catch {
            XCTAssertEqual(mock.callCount, 2)
        }
    }

    func testInvalidGradeDoesNotDecodeAsB() async throws {
        let response = """
        {
          "assets": [
            {
              "type": "viewpoint",
              "grade": "C",
              "title": "弱观点",
              "content": "普通流水账",
              "source_record_ids": ["r1"]
            }
          ]
        }
        """
        let mock = MockLLMClient(responses: [response])
        let provider = RemoteAssetExtractionProvider(clientOverride: mock)

        let result = try await provider.requestAndParse(
            client: mock,
            input: "记录",
            prompt: "提示",
            config: dummyConfig
        )

        XCTAssertNil(result.assets.first?.grade)
    }
}
