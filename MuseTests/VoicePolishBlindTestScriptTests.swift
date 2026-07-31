import XCTest

final class VoicePolishBlindTestScriptTests: XCTestCase {
    func testPrepareRandomizesThirtySamplesAndScoreAppliesEightyFivePercentGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseVoicePolishBlindTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let input = root.appendingPathComponent("input.json")
        let evaluation = root.appendingPathComponent("evaluation.json")
        let key = root.appendingPathComponent("key.json")
        let report = root.appendingPathComponent("report.json")
        let samples: [[String: String]] = (0..<30).map {
            [
                "id": "sample-\($0)",
                "input": "input-\($0)",
                "legacy_output": "legacy-\($0)",
                "new_output": "new-\($0)",
            ]
        }
        try JSONSerialization.data(withJSONObject: ["samples": samples])
            .write(to: input, options: .atomic)

        let script = projectRoot.appendingPathComponent("scripts/voice-polish-blind-test.py")
        XCTAssertEqual(try runPython([
            script.path, "prepare",
            "--input", input.path,
            "--output", evaluation.path,
            "--key", key.path,
            "--seed", "7",
        ]), 0)

        var publicDocument = try json(at: evaluation)
        var publicSamples = publicDocument["samples"] as! [[String: Any]]
        for index in publicSamples.indices {
            publicSamples[index]["rating"] = index < 26 ? "tie" : "both_unusable"
        }
        publicDocument["samples"] = publicSamples
        try JSONSerialization.data(withJSONObject: publicDocument, options: [.prettyPrinted, .sortedKeys])
            .write(to: evaluation, options: .atomic)

        XCTAssertEqual(try runPython([
            script.path, "score",
            "--evaluation", evaluation.path,
            "--key", key.path,
            "--output", report.path,
        ]), 0)
        let scored = try json(at: report)
        XCTAssertEqual(scored["baseline_commit"] as? String, "b81bce5")
        XCTAssertEqual(scored["sample_count"] as? Int, 30)
        XCTAssertEqual(scored["product_ready"] as? Bool, true)
        XCTAssertEqual(scored["new_win_or_tie_rate"] as? Double ?? 0, 26.0 / 30.0, accuracy: 0.0001)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runPython(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
