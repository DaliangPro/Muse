import XCTest
@testable import Muse

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testInitialStateIsIdle() async {
        let session = makeSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = makeSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = makeSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = makeSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForVolcano() async {
        KeychainService.selectedASRProvider = .volcano
        let session = makeSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testReadyEventsAreDeduplicated() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }

        await session.handleASREventForTesting(.ready)
        await session.handleASREventForTesting(.ready)

        XCTAssertEqual(recorder.values, ["ready"])
        let emittedReady = await session.hasEmittedReadyForTesting
        XCTAssertTrue(emittedReady)
    }

    func testTranscriptEventUpdatesStoredTranscriptAndForwardsToUI() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: ["hello "],
            partialText: "world",
            authoritativeText: "",
            isFinal: false
        )

        await session.handleASREventForTesting(.transcript(transcript))

        XCTAssertEqual(recorder.values, ["transcript:hello world"])
        let storedTranscript = await session.transcriptForTesting
        XCTAssertEqual(storedTranscript, transcript)
    }

    func testStaleASREventsAreIgnoredAfterSessionChanges() async throws {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.handleASREventForTesting(.ready)
        let staleSessionIDCandidate = await session.currentSessionIDForTesting
        let staleSessionID = try XCTUnwrap(staleSessionIDCandidate)
        await session.setState(.recording)
        await session.forceResetForTesting()

        await session.handleASREventForTesting(
            .transcript(RecognitionTranscript(
                confirmedSegments: ["stale"],
                partialText: "",
                authoritativeText: "",
                isFinal: true
            )),
            expectedSessionID: staleSessionID
        )

        XCTAssertEqual(recorder.values, ["ready"])
        let storedTranscript = await session.transcriptForTesting
        XCTAssertEqual(storedTranscript, .empty)
    }

    func testAbortCurrentSessionWhileIdleEmitsCompletedForUICleanup() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }

        await session.abortCurrentSession()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testAbortCurrentSessionFromStartingResetsToIdleAndEmitsCompleted() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.starting)

        await session.abortCurrentSession()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testASRErrorWhileRecordingPreservesSessionForStopTimeRecovery() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.recording)

        await session.handleASREventForTesting(.error(NSError(
            domain: "RecognitionSessionTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "ASR failed"]
        )))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    func testStopDuringStartingEmitsCompletedForUICleanup() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.starting)

        await session.stopRecording()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testStreamingInterruptedKeepsRecordingActive() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.recording)

        await session.handleASREventForTesting(.streamingInterrupted)

        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    func testVoicePolishWaitsForFinalTranscriptAndCallsLLMWithEmptyRequirements() async throws {
        let source = "明天下午三点开会。"
        let client = RecognitionSessionVoicePolishLLM(response: source)
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.switchMode(to: .formalWriting)
        await session.setState(.recording)
        await session.handleASREventForTesting(.transcript(RecognitionTranscript(
            confirmedSegments: [],
            partialText: "明天下午",
            authoritativeText: "",
            isFinal: false
        )))
        try await Task.sleep(for: .milliseconds(900))
        let speculativeCount = await client.requestCount()
        XCTAssertEqual(speculativeCount, 0)

        let finalTranscript = RecognitionTranscript(
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )
        let result = await session.postProcessVoicePolishForTesting(
            rawText: source,
            transcript: finalTranscript
        )

        XCTAssertEqual(result?.finalText, source)
        XCTAssertEqual(result?.processedText, source)
        XCTAssertEqual(result?.llmFailed, false)
        XCTAssertEqual(result?.historyStatus, "voice_polish_success")
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].task, .voicePolishFast)
        XCTAssertTrue(requests[0].user.contains(#""user_preferences":"""#))
        XCTAssertTrue(requests[0].user.contains(source))
    }

    func testVoicePolishUsesCanonicalTextAndCompleteEffectiveSnippetRules() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "把这整句替换掉。", value: "内置整句。"),
        ], context: fixture.context)
        try SnippetStorage.save([
            (trigger: "Code X", value: "Codex"),
            (trigger: "把这整句替换掉。", value: "用户整句。"),
        ], context: fixture.context)
        VoicePolishSettings.setModelOverride(
            "voice-polish-fast-model",
            defaults: fixture.context.userDefaults
        )
        let raw = "我在用 Type less、Cloud Code 和 Code X。把这整句替换掉。"
        let canonical = "我在用 Typeless、Claude Code 和 Codex。用户整句。"
        let client = RecognitionSessionVoicePolishLLM(response: canonical)
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, canonical)
        XCTAssertEqual(result?.processedText, canonical)
        XCTAssertFalse(result?.llmFailed ?? true)
        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let payload = try Self.voicePolishPayload(from: request)
        XCTAssertEqual(payload["provider_final_text"] as? String, raw)
        XCTAssertEqual(payload["canonical_text"] as? String, canonical)
        let rawSegments = try XCTUnwrap(payload["raw_source_segments"] as? [[String: Any]])
        XCTAssertEqual(rawSegments.compactMap { $0["text"] as? String }, [raw])
        let canonicalSegments = try XCTUnwrap(payload["source_segments"] as? [[String: Any]])
        XCTAssertEqual(canonicalSegments.compactMap { $0["text"] as? String }, [canonical])
        XCTAssertFalse(request.user.contains("内置整句"))
        let models = await client.recordedModels()
        XCTAssertEqual(models, ["voice-polish-fast-model"])
    }

    func testVoicePolishScopesTerminologyByApplicationBeforeCanonicalization() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application("com.example.app-a")
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let otherApplicationSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let otherResult = await otherApplicationSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: "com.example.app-b"),
            vocabularyContext: fixture.context
        )
        XCTAssertEqual(otherResult?.finalText, raw)

        let client = RecognitionSessionVoicePolishLLM(response: canonical)
        let targetApplicationSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        let targetResult = await targetApplicationSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: "com.example.app-a"),
            vocabularyContext: fixture.context
        )
        XCTAssertEqual(targetResult?.finalText, canonical)
        let targetRequests = await client.recordedRequests()
        let request = try XCTUnwrap(targetRequests.first)
        let payload = try Self.voicePolishPayload(from: request)
        XCTAssertEqual(payload["provider_final_text"] as? String, raw)
        XCTAssertEqual(payload["canonical_text"] as? String, canonical)
    }

    func testVoicePolishDoesNotBypassRepositorySuppressionThroughLegacySnippets() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.save([
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "旧的整句模板。", value: "固定替换成功。"),
        ], context: fixture.context)
        // 空的统一词库会把仍留在兼容文件中的旧术语规则标记为 suppressed。
        // Voice Polish 不能再通过 SnippetStorage.applyEffective 绕过这个决定。
        try TerminologyRepository.save(.empty, context: fixture.context)
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Cloud Code" && $0.value == "Claude Code"
        })
        let raw = "请打开 Cloud Code。旧的整句模板。"
        let expected = "请打开 Cloud Code。固定替换成功。"
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, expected)
    }

    func testVoicePolishUsesAndRemembersRecentMuseInputsOnlyWhenEnabled() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        VoicePolishSettings.setRecentInputContextEnabled(
            true,
            defaults: fixture.context.userDefaults
        )
        let applicationID = "com.example.chat"
        let recentStore = VoicePolishRecentInputContextStore()
        await recentStore.remember(
            "上一条 Muse 输入",
            applicationBundleID: applicationID
        )
        let raw = "这是本次口述。"
        let polished = "这是本次成稿。"
        let client = RecognitionSessionVoicePolishLLM(response: polished)
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            },
            voicePolishRecentInputStore: recentStore
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(
                applicationBundleID: applicationID,
                scene: .chat
            ),
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, polished)
        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let payload = try Self.voicePolishPayload(from: request)
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["recent_muse_inputs"] as? [String], ["上一条 Muse 输入"])
        let rememberedInputs = await recentStore.recentInputs(
            applicationBundleID: applicationID
        )
        XCTAssertEqual(rememberedInputs, ["上一条 Muse 输入", polished])
    }

    func testVoicePolishEmitsStageAndCanImmediatelyUseCanonicalText() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let client = RecognitionSessionBlockingVoicePolishLLM()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let vocabularyContext = fixture.context
        async let processingResult = session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: vocabularyContext
        )

        for _ in 0..<100 {
            if await client.requestCount() > 0,
               recorder.values.contains("voicePolishStage:polishing") {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
        let accepted = await session.useCanonicalVoicePolishResult()
        XCTAssertTrue(accepted)
        let result = await processingResult

        XCTAssertEqual(result?.finalText, canonical)
        XCTAssertNil(result?.processedText)
        XCTAssertFalse(result?.llmFailed ?? true)
        XCTAssertEqual(result?.historyStatus, "voice_polish_canonical")
        XCTAssertTrue(recorder.values.contains("voicePolishStage:polishing"))
        XCTAssertTrue(recorder.values.contains("processing:\(canonical)"))
    }

    func testVoicePolishCanonicalRequestIsRejectedAfterPipelineResultCommitted() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let polished = "这是已经提交的润色结果。"
        let client = RecognitionSessionVoicePolishLLM(response: polished)
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let raw = "这是需要润色的原始口述。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )
        let acceptedAfterCommit = await session.useCanonicalVoicePolishResult()

        XCTAssertEqual(result?.finalText, polished)
        XCTAssertTrue(recorder.values.contains("processing:\(polished)"))
        XCTAssertFalse(acceptedAfterCommit)
    }

    func testVoicePolishFallbackUsesCanonicalTextInsteadOfRawTranscript() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, canonical)
        XCTAssertNil(result?.processedText)
        XCTAssertTrue(result?.llmFailed ?? false)
        XCTAssertEqual(result?.historyStatus, "voice_polish_fallback")
    }

    private static func voicePolishPayload(from request: LLMRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(request.user.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - REPAIR_PLAN K2：注入取值守卫与时长合理性

    func testEffectiveTextPrefersAuthoritativeWhenComparable() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["今天先到这里，", "明天继续。"],
            partialText: "",
            authoritativeText: "今天先到这里，明天继续。",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "今天先到这里，明天继续。"
        )
    }

    func testEffectiveTextFallsBackWhenAuthoritativeSuspiciouslyShort() {
        // 实锤形态：流式累积完整、asyncFinal 的 result.text 只承载开头一小段
        let composedPieces = ["OK，然后现在还是有问题，", "就是我现在有一个语音输入法嘛，", "然后我输入的文字少了很多"]
        let transcript = RecognitionTranscript(
            confirmedSegments: composedPieces,
            partialText: "",
            authoritativeText: "OK，然后",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            composedPieces.joined()
        )
    }

    func testEffectiveTextUsesComposedWhenAuthoritativeEmpty() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["第一段"],
            partialText: "第二段",
            authoritativeText: "",
            isFinal: false
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "第一段第二段"
        )
    }

    func testEffectiveTextUsesAuthoritativeWhenComposedEmpty() {
        let transcript = RecognitionTranscript(
            confirmedSegments: [],
            partialText: "",
            authoritativeText: "最终文本",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "最终文本"
        )
    }

    func testImplausiblyShortRequiresLongRecording() {
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 3, durationSeconds: 8.0
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 4, durationSeconds: 10.0
        ))
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5, durationSeconds: 10.0
        ))
    }

    func testImplausiblyShortIgnoresEmptyText() {
        // 这个旧启发式只看时长/字数，0 字交给 K7 的 PCM 活动摘要另行判断。
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 0, durationSeconds: 30.0
        ))
    }

    func testImplausiblyShortCatchesHistoricalLossCases() {
        // history.db 实锤：22.2s/5 字、53.6s/6 字、19.0s/3 字
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5, durationSeconds: 22.2
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 6, durationSeconds: 53.6
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 3, durationSeconds: 19.0
        ))
    }

    func testImplausiblyShortUsesVoicedDurationInsteadOfWallClockDuration() {
        // 2026-07-31 现场：57.2 秒录音中只有 269 个 20ms 有声帧（约 5.38 秒），
        // 27 字是完整的正常语速，不应因长停顿触发近一分钟全文重识别。
        let summary = PCMAudioActivitySummary(
            validByteCount: 1_812_980,
            analyzedFrameCount: 2_833,
            voicedFrameCount: 269,
            peakAmplitude: 20_196
        )

        XCTAssertEqual(summary.voicedDurationSeconds, 5.38, accuracy: 0.001)
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 27,
            audioSummary: summary
        ))
    }

    func testImplausiblyShortStillCatchesLongVoicedAudioWithTooLittleText() {
        let summary = PCMAudioActivitySummary(
            validByteCount: 710_400,
            analyzedFrameCount: 1_110,
            voicedFrameCount: 1_110,
            peakAmplitude: 8_000
        )

        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5,
            audioSummary: summary
        ))
    }

    func testPacedFallbackTimeoutCoversRealtimeReplayDuration() {
        // 60 秒 PCM + 15 秒服务端收尾余量
        XCTAssertEqual(
            RecognitionSession.batchFallbackTimeout(
                provider: .aliyun,
                audioByteCount: 60 * 16_000 * MemoryLayout<Int16>.size
            ),
            .seconds(75)
        )
        XCTAssertEqual(
            RecognitionSession.batchFallbackTimeout(
                provider: .volcano,
                audioByteCount: 60 * 16_000 * MemoryLayout<Int16>.size
            ),
            .seconds(75)
        )
    }

    private func makeSession() -> RecognitionSession {
        RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
    }
}

private final class RecognitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            storage.append(Self.describe(event))
        }
    }

    private static func describe(_ event: RecognitionEvent) -> String {
        switch event {
        case .ready:
            return "ready"
        case .transcript(let transcript):
            return "transcript:\(transcript.displayText)"
        case .error(let error):
            return "error:\(error.localizedDescription)"
        case .completed:
            return "completed"
        case .processingResult(let text):
            return "processing:\(text)"
        case .voicePolishStage(let stage):
            return "voicePolishStage:\(stage.rawValue)"
        case .finalized(let text, let injection):
            return "finalized:\(text):\(injection)"
        case .streamingInterrupted:
            return "streamingInterrupted"
        }
    }
}

private actor RecognitionSessionBlockingVoicePolishLLM: LLMClient {
    private var requests: [LLMRequest] = []

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        try await Task.sleep(for: .seconds(30))
        return LLMResponse(text: "不应等待到这里", model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        XCTFail("Voice Polish 不应回到兼容 process 接口")
        return text
    }

    func warmUp(baseURL: String) async {}

    func requestCount() -> Int { requests.count }
}

private actor RecognitionSessionVoicePolishLLM: LLMClient {
    private let response: String
    private var requests: [LLMRequest] = []
    private var models: [String] = []

    init(response: String) {
        self.response = response
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        models.append(config.model)
        return LLMResponse(text: response, model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        XCTFail("Voice Polish 不应回到兼容 process 接口")
        return response
    }

    func warmUp(baseURL: String) async {}

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [LLMRequest] { requests }
    func recordedModels() -> [String] { models }
}

private final class RecognitionSessionVocabularyFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseRecognitionSessionVocabularyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MuseRecognitionSessionVocabularyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
