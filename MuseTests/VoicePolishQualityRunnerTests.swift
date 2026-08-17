import XCTest
@testable import Muse

final class VoicePolishQualityRunnerTests: XCTestCase {
    func test普通启动不进入质量跑测() throws {
        XCTAssertNil(try VoicePolishQualityRunner.parseInvocation(arguments: ["Muse"]))
        XCTAssertFalse(VoicePolishQualityRunner.isRequested(arguments: ["Muse"]))
    }

    func test质量跑测在正常App构建前可被分流() {
        let arguments = ["Muse", "--voice-polish-quality-run"]

        XCTAssertTrue(VoicePolishQualityRunner.isRequested(arguments: arguments))
    }

    func test显式参数可解析且不需要凭据参数() throws {
        let invocation = try XCTUnwrap(VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse",
            "--voice-polish-quality-run",
            "--dataset", "/tmp/dataset.json",
            "--report", "/tmp/report.json",
            "--limit", "9",
            "--commit", "abc1234",
        ]))

        XCTAssertEqual(invocation.datasetPath, "/tmp/dataset.json")
        XCTAssertEqual(invocation.reportPath, "/tmp/report.json")
        XCTAssertEqual(invocation.limit, 9)
        XCTAssertEqual(invocation.commit, "abc1234")
    }

    func test非法数量参数会被拒绝() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse",
            "--voice-polish-quality-run",
            "--dataset", "/tmp/dataset.json",
            "--report", "/tmp/report.json",
            "--limit", "0",
        ]))
    }

    func test多维产品质量母集可完整解析为107次输入() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let datasetPath = repositoryRoot
            .appendingPathComponent("docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json")
            .path

        XCTAssertEqual(
            try VoicePolishQualityRunner.validatedInputCount(at: datasetPath),
            107
        )
    }
}
