import XCTest
@testable import Muse

final class DoubaoChatClientTests: XCTestCase {

    func testPromptAndUserInputAreSeparatedForLLMRequest() {
        let prompt = "请修正以下文本：{text}\n只返回正文。"
        let parts = prompt.separatedLLMMessages(with: "200毫秒")

        XCTAssertEqual(parts.system, "请修正以下文本：\n只返回正文。")
        XCTAssertEqual(parts.user, "200毫秒")
        XCTAssertFalse(parts.system?.contains("200毫秒") ?? true)
    }
}
