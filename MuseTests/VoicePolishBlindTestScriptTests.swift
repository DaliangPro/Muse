import XCTest

final class VoicePolishBlindTestScriptTests: XCTestCase {
    func testPrepareRandomizesOneHundredSamplesAndAppliesFullProductGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseVoicePolishBlindTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let input = root.appendingPathComponent("input.json")
        let evaluation = root.appendingPathComponent("evaluation.json")
        let key = root.appendingPathComponent("key.json")
        let report = root.appendingPathComponent("report.json")
        let samples: [[String: Any]] = (0..<100).map {
            let route = $0 % 10 == 0 ? "deep" : ($0 % 3 == 0 ? "structured" : "fast")
            return [
                "id": "sample-\($0)",
                "audio_ref": "audio/sample-\($0).wav",
                "category": "terminology",
                "reference_transcript": "input-\($0)",
                "typeless_output": "typeless-\($0)",
                "muse_output": "muse-\($0)",
                "typeless_latency_ms": 1_000,
                "muse_metrics": [
                    "latency_ms": route == "deep" ? 4_000 : 1_000,
                    "route": route,
                    "call_count": 1,
                    "repair_used": false,
                    "fallback_used": false,
                    "confirmed_alias_total": 1,
                    "confirmed_alias_correct": 1,
                    "critical_fact_total": 1,
                    "critical_fact_preserved": 1,
                    "whitelist_hallucination_count": 0,
                ],
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
            "--baseline-commit", "test-baseline",
        ]), 0)

        var publicDocument = try json(at: evaluation)
        var publicSamples = publicDocument["samples"] as! [[String: Any]]
        for index in publicSamples.indices {
            publicSamples[index]["ratings"] = [
                "overall": "tie",
                "writing_quality": "tie",
                "terminology": "tie",
                "fact_preservation": "tie",
                "sendability": "tie",
            ]
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
        XCTAssertEqual(scored["baseline_commit"] as? String, "test-baseline")
        XCTAssertEqual(scored["sample_count"] as? Int, 100)
        XCTAssertEqual(scored["product_ready"] as? Bool, true)
        let dimensions = scored["dimensions"] as! [String: Any]
        let overall = dimensions["overall"] as! [String: Any]
        XCTAssertEqual(overall["muse_win_or_tie_rate"] as? Double, 1)
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
