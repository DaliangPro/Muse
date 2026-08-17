import XCTest
@testable import Muse

final class VoicePolishQualityRunnerTests: XCTestCase {
    private let runNonce = String(repeating: "a", count: 64)

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
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
            "--limit", "9",
        ]))

        XCTAssertEqual(invocation.runInputPath, "/tmp/runner-input.json")
        XCTAssertEqual(invocation.reportPath, "/tmp/report.json")
        XCTAssertEqual(invocation.providerAuditPath, "/tmp/provider-audit.jsonl")
        XCTAssertEqual(invocation.runNonce, runNonce)
        XCTAssertEqual(invocation.limit, 9)
    }

    func test非法数量参数会被拒绝() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse",
            "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", runNonce,
            "--limit", "0",
        ]))
    }

    func test缺失或非法一次性运行标识会被拒绝() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse", "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
        ]))
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse", "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--provider-audit", "/tmp/provider-audit.jsonl",
            "--run-nonce", "not-a-valid-nonce",
        ]))
    }

    func test质量跑测必须由Evaluator指定独立Provider回执路径() {
        XCTAssertThrowsError(try VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse",
            "--voice-polish-quality-run",
            "--run-input", "/tmp/runner-input.json",
            "--report", "/tmp/report.json",
            "--run-nonce", runNonce,
        ]))
    }

    func test制品哈希由Runner读取文件计算且不能被CLI字段冒充() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseQualityRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let executableURL = fixtureDirectory.appendingPathComponent("Muse")
        try Data("abc".utf8).write(to: runInputURL)
        try Data("binary".utf8).write(to: executableURL)

        let invocation = try XCTUnwrap(VoicePolishQualityRunner.parseInvocation(arguments: [
            "Muse",
            "--voice-polish-quality-run",
            "--run-input", runInputURL.path,
            "--report", fixtureDirectory.appendingPathComponent("report.json").path,
            "--provider-audit", fixtureDirectory.appendingPathComponent("provider-audit.jsonl").path,
            "--run-nonce", runNonce,
            "--commit", "可由CLI填写但Runner不得采用",
            "--run-input-sha256", "伪造的运行输入哈希",
            "--executable-sha256", "伪造的二进制哈希",
        ]))
        let evidence = try VoicePolishQualityRunner.artifactEvidenceForTesting(
            runInputURL: URL(fileURLWithPath: invocation.runInputPath),
            executableURL: executableURL
        )

        XCTAssertEqual(
            evidence.runInputSHA256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            evidence.executableSHA256,
            "9a3a45d01531a20e89ac6ae10b0b0beb0492acd7216a368aa062d1a5fecaf9cd"
        )
        XCTAssertEqual(evidence.sourceCommit, String(repeating: "0", count: 40))

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [String: String]
        )
        XCTAssertEqual(object["run_input_sha256"], evidence.runInputSHA256)
        XCTAssertEqual(object["executable_sha256"], evidence.executableSHA256)
        XCTAssertEqual(object["source_commit"], evidence.sourceCommit)
    }

    func test非法制品提交标识会被拒绝() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseQualityRunnerCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let executableURL = fixtureDirectory.appendingPathComponent("Muse")
        try Data("runner-input".utf8).write(to: runInputURL)
        try Data("binary".utf8).write(to: executableURL)

        XCTAssertThrowsError(try VoicePolishQualityRunner.artifactEvidenceForTesting(
            runInputURL: runInputURL,
            executableURL: executableURL,
            sourceCommit: "可由调用方伪造"
        ))
    }

    func test报告输入证据完整保留实际分段与上下文夹具() throws {
        let fixture = VoicePolishQualityRunner.QualityContextFixture(
            type: "secure_context",
            level: .nearbyText,
            safety: .secure,
            selectedText: nil,
            textBeforeCursor: "上文中的项目代号是星桥",
            textAfterCursor: nil,
            recentMuseInputs: ["上一条 Muse 输入"]
        )
        let evidence = VoicePolishQualityRunner.reportInputEvidence(
            segmentTexts: ["第一段原始语音", "第二段原始语音"],
            contextFixture: fixture,
            contextType: "secure_context",
            appliedContext: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .secure
            )
        )

        XCTAssertEqual(evidence.segmentTexts, ["第一段原始语音", "第二段原始语音"])
        XCTAssertEqual(evidence.contextFixture, fixture)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(evidence)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["segment_texts"] as? [String],
            ["第一段原始语音", "第二段原始语音"]
        )
        let contextObject = try XCTUnwrap(object["context_fixture"] as? [String: Any])
        XCTAssertEqual(contextObject["type"] as? String, "secure_context")
        XCTAssertEqual(contextObject["level"] as? String, "nearbyText")
        XCTAssertEqual(contextObject["safety"] as? String, "secure")
        XCTAssertTrue(contextObject["selected_text"] is NSNull)
        XCTAssertEqual(
            contextObject["text_before_cursor"] as? String,
            "上文中的项目代号是星桥"
        )
        XCTAssertTrue(contextObject["text_after_cursor"] is NSNull)
        XCTAssertEqual(contextObject["recent_muse_inputs"] as? [String], ["上一条 Muse 输入"])

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(
            try decoder.decode(VoicePolishQualityRunner.QualityReportInputEvidence.self, from: data),
            evidence
        )
    }

    func test没有显式上下文夹具时报告仍写出实际默认上下文() {
        let appliedContext = WritingContext(
            scene: .chat,
            level: .metadataOnly,
            safety: .unknown,
            recentMuseInputs: ["最近一次输入"]
        )

        let evidence = VoicePolishQualityRunner.reportInputEvidence(
            segmentTexts: ["请你明天提醒我"],
            contextFixture: nil,
            contextType: "none",
            appliedContext: appliedContext
        )

        XCTAssertEqual(evidence.contextFixture.type, "none")
        XCTAssertEqual(evidence.contextFixture.level, .metadataOnly)
        XCTAssertEqual(evidence.contextFixture.safety, .unknown)
        XCTAssertNil(evidence.contextFixture.selectedText)
        XCTAssertNil(evidence.contextFixture.textBeforeCursor)
        XCTAssertNil(evidence.contextFixture.textAfterCursor)
        XCTAssertEqual(evidence.contextFixture.recentMuseInputs, ["最近一次输入"])
    }

    func testEvaluator从130次母集派生的Runner输入不含答案字段且可解析() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let datasetPath = repositoryRoot
            .appendingPathComponent("docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json")
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseQualityRunnerInputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        let output = try runPython(
            """
            import importlib.util, json, pathlib, sys
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            master = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
            runner_input = module.build_runner_input_document(master)
            pathlib.Path(sys.argv[3]).write_text(
                json.dumps(runner_input, ensure_ascii=False),
                encoding="utf-8",
            )
            leaked = sorted({
                key
                for item in runner_input["inputs"]
                for key in item
                if key in module.RUNNER_FORBIDDEN_ANSWER_FIELDS
            })
            print(json.dumps({
                "count": len(runner_input["inputs"]),
                "document_keys": sorted(runner_input),
                "leaked": leaked,
            }, ensure_ascii=False))
            """,
            arguments: [scriptPath.path, datasetPath.path, runInputURL.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(summary["count"] as? Int, 130)
        XCTAssertEqual(
            summary["document_keys"] as? [String],
            ["inputs", "name", "schema_version"]
        )
        XCTAssertEqual(summary["leaked"] as? [String], [])
        XCTAssertEqual(try VoicePolishQualityRunner.validatedInputCount(at: runInputURL.path), 130)
    }

    func testRunner拒绝夹带答案字段的运行输入() throws {
        let runInput: [String: Any] = [
            "schema_version": 1,
            "name": "forbidden-answer-fixture",
            "inputs": [[
                "test_input_id": "case-1",
                "base_case_id": "case-1",
                "input_kind": "base",
                "writing_scene": "chat",
                "spoken_input": "嗯明天见",
                "preconditions": [],
                "context_type": "none",
                "segment_texts": ["嗯明天见"],
                "context_fixture": NSNull(),
                "reference_output": "明天见。",
            ]],
        ]
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseQualityRunnerForbiddenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let runInputURL = fixtureDirectory.appendingPathComponent("runner-input.json")
        try JSONSerialization.data(withJSONObject: runInput).write(to: runInputURL)

        XCTAssertThrowsError(try VoicePolishQualityRunner.validatedInputCount(at: runInputURL.path))
    }

    func test硬校验码与诊断码分开记录() {
        let evidence = VoicePolishQualityRunner.validationEvidence(for: [
            .sceneStyleMismatch,
            .missingProtectedFact,
            .semanticDecisionUnverified,
        ])

        XCTAssertEqual(evidence.hardValidationCodes, ["missingProtectedFact"])
        XCTAssertEqual(
            evidence.diagnosticCodes,
            ["sceneStyleMismatch", "semanticDecisionUnverified"]
        )
    }

    func test内部切片数按Fast实际分片计算() {
        let source = "第一句内容。第二句内容。第三句内容。第四句内容。"

        XCTAssertGreaterThan(
            VoicePolishQualityRunner.internalChunkCount(
                for: source,
                executedRoute: .fast,
                maximumSourceTokens: 6
            ),
            1
        )
        XCTAssertEqual(
            VoicePolishQualityRunner.internalChunkCount(
                for: source,
                executedRoute: .structured,
                maximumSourceTokens: 6
            ),
            1
        )
    }

    func test质量报告记录最终ChatCompletions地址() throws {
        XCTAssertEqual(
            try VoicePolishQualityRunner.endpointIdentity(
                rawBaseURL: "https://api.deepseek.com",
                provider: .deepseek
            ),
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            try VoicePolishQualityRunner.endpointIdentity(
                rawBaseURL: "https://example.com/v1/",
                provider: .openai
            ),
            "https://example.com/v1/chat/completions"
        )
    }

    func testEvaluator只因硬校验失败并要求调用覆盖切片() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let output = try runPython(
            """
            import importlib.util, json, pathlib, sys
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            base = {
                "internal_chunk_count": 2,
                "llm_call_count": 2,
                "latency_milliseconds": 1,
                "hard_validation_codes": [],
                "diagnostic_codes": ["sceneStyleMismatch"],
            }
            diagnostic_only = module.runtime_evidence_failures(base)
            too_few_calls = module.runtime_evidence_failures({**base, "llm_call_count": 1})
            hard_failure = module.runtime_evidence_failures({
                **base,
                "hard_validation_codes": ["missingProtectedFact"],
            })
            print(json.dumps({
                "diagnostic_only": diagnostic_only,
                "too_few_calls": too_few_calls,
                "hard_failure": hard_failure,
            }, ensure_ascii=False))
            """,
            arguments: [scriptPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String]]
        )

        XCTAssertEqual(result["diagnostic_only"], [])
        XCTAssertTrue(result["too_few_calls", default: []].contains { $0.contains("少于内部切片数") })
        XCTAssertTrue(result["hard_failure", default: []].contains { $0.contains("硬校验错误") })
    }

    func testEvaluator只信外部冻结的构建Manifest与Expected值() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let output = try runPython(
            """
            import hashlib, importlib.util, json, pathlib, sys, tempfile
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            directory = pathlib.Path(tempfile.mkdtemp(prefix="MuseManifestEvaluatorTests-"))
            path = directory / "quality-build-manifest.json"
            commit = "1" * 40
            tree = "2" * 40
            executable = "3" * 64
            requirement = 'identifier "pro.daliang.muse" and certificate leaf = H"abc"'
            requirement_hash = hashlib.sha256(requirement.encode("utf-8")).hexdigest()
            document = {
                "schema_version": 1,
                "artifact_kind": "muse_voice_polish_quality_candidate",
                "package_mode": "production",
                "bundle_id": "pro.daliang.muse",
                "source_commit": commit,
                "source_tree": tree,
                "executable_sha256": executable,
                "designated_requirement": requirement,
                "designated_requirement_sha256": requirement_hash,
                "created_at": "2026-08-17T00:00:00Z",
            }
            path.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
            manifest_hash = module.sha256_file(path)
            valid = module.validated_build_manifest(
                path,
                expected_manifest_sha256=manifest_hash,
                expected_source_commit=commit,
                expected_source_tree=tree,
                expected_executable_sha256=executable,
                expected_designated_requirement_sha256=requirement_hash,
            )
            rejected = False
            try:
                module.validated_build_manifest(
                    path,
                    expected_manifest_sha256=manifest_hash,
                    expected_source_commit=commit,
                    expected_source_tree=tree,
                    expected_executable_sha256="4" * 64,
                    expected_designated_requirement_sha256=requirement_hash,
                )
            except ValueError:
                rejected = True
            print(json.dumps({"commit": valid["source_commit"], "rejected": rejected}))
            """,
            arguments: [scriptPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["commit"] as? String, String(repeating: "1", count: 40))
        XCTAssertEqual(result["rejected"] as? Bool, true)
    }

    func testEvaluator要求网络回执与每条LLM调用一一对应() throws {
        let scriptPath = repositoryRoot
            .appendingPathComponent("scripts/evaluate-voice-polish-quality-report.py")
        let output = try runPython(
            """
            import datetime, importlib.util, json, pathlib, sys
            script = pathlib.Path(sys.argv[1])
            sys.path.insert(0, str(script.parent))
            spec = importlib.util.spec_from_file_location("voice_polish_evaluator", script)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            now = datetime.datetime.now(datetime.timezone.utc)
            nonce = "a" * 64
            receipt = {
                "schema_version": 1,
                "run_nonce": nonce,
                "test_input_id": "VP-001",
                "request_ordinal": 1,
                "llm_task": "voicePolishFast",
                "provider": "deepseek",
                "endpoint_url": "https://api.deepseek.com/chat/completions",
                "configured_model": "deepseek-chat",
                "response_model": "deepseek-chat",
                "transport": "stream",
                "http_status": 200,
                "request_body_sha256": "1" * 64,
                "response_text_sha256": "2" * 64,
                "provider_response_id": "chatcmpl-real-1",
                "recorded_at": now.isoformat(),
            }
            kwargs = {
                "expected_run_nonce": nonce,
                "expected_provider": "deepseek",
                "expected_model": "deepseek-chat",
                "expected_endpoint_url": "https://api.deepseek.com/chat/completions",
                "expected_test_ids": {"VP-001"},
                "actual_by_id": {"VP-001": {"llm_call_count": 1}},
                "run_started_at": now - datetime.timedelta(seconds=1),
                "run_finished_at": now + datetime.timedelta(seconds=1),
            }
            print(json.dumps({
                "valid": module.provider_audit_failures([receipt], **kwargs),
                "zero_receipt": module.provider_audit_failures([], **kwargs),
                "missing_response_id": module.provider_audit_failures([
                    {**receipt, "provider_response_id": ""}
                ], **kwargs),
            }, ensure_ascii=False))
            """,
            arguments: [scriptPath.path]
        )
        let data = try XCTUnwrap(output.data(using: .utf8))
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String]]
        )
        XCTAssertEqual(result["valid"], [])
        XCTAssertTrue(result["zero_receipt", default: []].contains { $0.contains("Provider 回执 0 条") })
        XCTAssertTrue(result["missing_response_id", default: []].contains { $0.contains("response ID") })
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runPython(_ source: String, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", source] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "VoicePolishQualityRunnerTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(data: error, encoding: .utf8) ?? "Python 执行失败",
                ]
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
