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

    func testStopDuringBlockedTargetApplicationCaptureCannotStartZombieSession() async throws {
        let gate = RecognitionSessionApplicationCaptureGate()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            frontmostApplicationBundleIdentifier: { await gate.capture() }
        )
        await session.setOnASREvent { recorder.record($0) }

        let startTask = Task { await session.startRecording(mode: .direct) }
        for _ in 0..<100 {
            if await gate.hasStarted { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStartCapture = await gate.hasStarted
        XCTAssertTrue(didStartCapture)

        await session.stopRecording()
        await gate.resolve("com.example.target")
        await startTask.value

        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(recorder.values.contains("completed"))
    }

    func testAbortDuringBlockedTargetApplicationCaptureCannotStartZombieSession() async throws {
        let gate = RecognitionSessionApplicationCaptureGate()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            frontmostApplicationBundleIdentifier: { await gate.capture() }
        )
        await session.setOnASREvent { recorder.record($0) }

        let startTask = Task { await session.startRecording(mode: .direct) }
        for _ in 0..<100 {
            if await gate.hasStarted { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStartCapture = await gate.hasStarted
        XCTAssertTrue(didStartCapture)

        await session.abortCurrentSession()
        await gate.resolve("com.example.target")
        await startTask.value

        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(recorder.values.contains("completed"))
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
        let sourceSpans = try XCTUnwrap(payload["source_spans"] as? [[String: Any]])
        XCTAssertEqual(sourceSpans.compactMap { $0["text"] as? String }.joined(), canonical)
        XCTAssertFalse(request.user.contains(raw))
        XCTAssertFalse(request.user.contains("内置整句"))
        let models = await client.recordedModels()
        XCTAssertEqual(models, Array(repeating: "voice-polish-fast-model", count: 3))
    }

    func testDirectAndVoicePolishShareGlobalCanonicalAndFixedSnippetBehavior() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        try SnippetStorage.save([
            (trigger: "旧的整句模板。", value: "固定替换成功。"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。旧的整句模板。"
        let expected = "我正在使用 Typeless。固定替换成功。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, expected)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
    }

    func testAllASRProvidersShareLocalCanonicalFinalization() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "type list")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 type list。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        for provider in ASRProvider.allCases {
            let session = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
            let result = await session.postProcessForTesting(
                rawText: raw,
                transcript: transcript,
                mode: .direct,
                provider: provider,
                vocabularyContext: fixture.context
            )
            XCTAssertEqual(result?.finalText, expected, provider.rawValue)
        }
    }

    func testDirectAndVoicePolishApplyApplicationTerminologyForSameTarget() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let targetApplication = "com.example.app-a"
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application(targetApplication)
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            applicationBundleIdentifier: targetApplication,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: targetApplication),
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, expected)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
    }

    func testApplicationTerminologyDoesNotLeakToOtherTargetInEitherMode() async throws {
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
        let otherApplication = "com.example.app-b"
        let raw = "我正在使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            applicationBundleIdentifier: otherApplication,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: otherApplication),
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, raw)
        XCTAssertEqual(voicePolishResult?.finalText, raw)
    }

    func testCapturedNilTargetDoesNotFallBackToLaterVoicePolishFocus() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let laterFocusedApplication = "com.example.later-focused"
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application(laterFocusedApplication)
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )

        let result = await session.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .formalWriting,
            writingContext: WritingContext(
                applicationBundleID: laterFocusedApplication
            ),
            applicationBundleIdentifier: nil,
            applicationBundleIdentifierWasCaptured: true,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, raw)
    }

    func testLegacyLLMAndVoicePolishFallbackBothUseCanonicalText() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let legacyLLMSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let legacyResult = await legacyLLMSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .smartDirect,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(legacyResult?.finalText, expected)
        XCTAssertTrue(legacyResult?.llmFailed ?? false)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
        XCTAssertTrue(voicePolishResult?.llmFailed ?? false)
    }

    func testConfirmedHistoryCorrectionIsCanonicalInNextRecognitionSession() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(.empty, context: fixture.context)
        let historyID = "history-confirmed-for-next-session"
        let historyStore = HistoryStore(
            path: fixture.directory.appendingPathComponent("history.db").path
        )
        await historyStore.insert(HistoryRecord(
            id: historyID,
            createdAt: Date(),
            durationSeconds: 1,
            rawText: "我正在使用 Type less。",
            processingMode: ProcessingMode.formalWriting.name,
            processedText: "我正在使用 Type less。",
            finalText: "我正在使用 Type less。",
            status: "voice_polish_success",
            characterCount: 18
        ))
        let coordinator = TerminologyHistoryTransactionCoordinator(context: fixture.context)
        _ = try await coordinator.confirmCorrection(
            historyStore: historyStore,
            historyID: historyID,
            candidates: [TerminologyCorrectionCandidate(
                alias: "Type less",
                canonical: "Typeless"
            )],
            correctedText: "我正在使用 Typeless。",
            scene: .document,
            personalizationEnabled: true,
            retentionLimit: 200,
            learnStyle: false,
            learnTerminology: true
        )

        let raw = "下一次继续使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let nextSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let nextResult = await nextSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(nextResult?.finalText, "下一次继续使用 Typeless。")
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
        let sourceSpans = try XCTUnwrap(payload["source_spans"] as? [[String: Any]])
        XCTAssertEqual(sourceSpans.compactMap { $0["text"] as? String }.joined(), canonical)
        XCTAssertFalse(request.user.contains(raw))
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
               recorder.values.contains("voicePolishStage:analyzing") {
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
        XCTAssertTrue(recorder.values.contains("voicePolishStage:analyzing"))
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

    func testVoicePolishFailureWaitsForExplicitCanonicalChoiceInsteadOfSilentInjection() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let vocabularyContext = fixture.context
        let source = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let wrong = source.replacingOccurrences(
            of: "邮件里不要承诺周五对外发布",
            with: "邮件里说明周五一定不会对外发布"
        )
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "constraint",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: ["s1"],
            status: "keep",
            modality: "not_promised",
            exactTokens: [],
            surfaceTokens: []
        )
        let ledger = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs",
                orderedUnitIds: ["u1"]
            )
        )
        let pass = VoicePolishReviewerResult(verdict: "pass", issues: [])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let wrongDraft = VoicePolishLedgerDraftDocument(fragments: [
            VoicePolishLedgerDraftFragment(id: "f_u1", unitIds: ["u1"], text: wrong),
        ])
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: [
            String(decoding: try encoder.encode(ledger), as: UTF8.self),
            String(decoding: try encoder.encode(wrongDraft), as: UTF8.self),
            String(decoding: try encoder.encode(pass), as: UTF8.self),
            String(decoding: try encoder.encode(wrongDraft), as: UTF8.self),
            String(decoding: try encoder.encode(pass), as: UTF8.self),
        ])
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
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )

        let pendingTask = Task {
            await session.postProcessVoicePolishForTesting(
                rawText: source,
                transcript: transcript,
                vocabularyContext: vocabularyContext,
                allowsUserChoice: true
            )
        }
        let reachedFiveRequests = await AsyncTimeout.asyncValue(.seconds(10)) {
            await client.waitForRequestCount(5)
            return true
        }
        let unavailable = await AsyncTimeout.asyncValue(.seconds(10)) {
            while !recorder.values.contains("voicePolishUnavailable:validationFailed"),
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return recorder.values.contains("voicePolishUnavailable:validationFailed")
        }

        let requestCount = await client.requestCount()
        XCTAssertFalse(reachedFiveRequests.timedOut, "requests=\(requestCount)")
        XCTAssertFalse(unavailable.timedOut, "events=\(recorder.values)")
        XCTAssertTrue(
            recorder.values.contains("voicePolishUnavailable:validationFailed"),
            "events=\(recorder.values) requests=\(requestCount)"
        )
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
        let accepted = await session.useCanonicalVoicePolishResult()
        XCTAssertTrue(accepted)
        let result = await pendingTask.value

        XCTAssertEqual(result?.finalText, source)
        XCTAssertNil(result?.processedText)
        XCTAssertFalse(result?.llmFailed ?? true)
        XCTAssertEqual(result?.historyStatus, "voice_polish_canonical")
        XCTAssertTrue(recorder.values.contains("processing:\(source)"))
    }

    func testVoicePolishExplicitRetryStartsFreshPipelineAndReturnsReviewedDraft() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let vocabularyContext = fixture.context
        let source = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let wrong = source.replacingOccurrences(
            of: "邮件里不要承诺周五对外发布",
            with: "邮件里说明周五一定不会对外发布"
        )
        let polished = "周五上午先发内部试看；邮件里不要承诺周五对外发布。"
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "constraint",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: ["s1"],
            status: "keep",
            modality: "not_promised",
            exactTokens: [],
            surfaceTokens: []
        )
        let ledger = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        let pass = VoicePolishReviewerResult(verdict: "pass", issues: [])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encodedLedger = String(decoding: try encoder.encode(ledger), as: UTF8.self)
        let encodedPass = String(decoding: try encoder.encode(pass), as: UTF8.self)
        func encodedDraft(_ text: String) throws -> String {
            String(decoding: try encoder.encode(VoicePolishLedgerDraftDocument(fragments: [
                VoicePolishLedgerDraftFragment(id: "f_u1", unitIds: ["u1"], text: text),
            ])), as: UTF8.self)
        }
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: [
            encodedLedger, try encodedDraft(wrong), encodedPass, try encodedDraft(wrong), encodedPass,
            encodedLedger, try encodedDraft(polished), encodedPass,
        ])
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(apiKey: "test", model: "mock-model", baseURL: "https://example.com/v1")
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )

        let pendingTask = Task {
            await session.postProcessVoicePolishForTesting(
                rawText: source,
                transcript: transcript,
                vocabularyContext: vocabularyContext,
                allowsUserChoice: true
            )
        }
        let firstRun = await AsyncTimeout.asyncValue(.seconds(10)) {
            while !recorder.values.contains("voicePolishUnavailable:validationFailed"),
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return recorder.values.contains("voicePolishUnavailable:validationFailed")
        }

        XCTAssertFalse(firstRun.timedOut)
        let firstRequestCount = await client.requestCount()
        XCTAssertEqual(firstRequestCount, 5)
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
        let retryAccepted = await session.retryVoicePolishResult()
        XCTAssertTrue(retryAccepted)
        let secondRun = await AsyncTimeout.asyncValue(.seconds(10)) {
            await client.waitForRequestCount(8)
            return true
        }
        let result = await pendingTask.value
        let requestCount = await client.requestCount()

        XCTAssertFalse(secondRun.timedOut)
        XCTAssertEqual(requestCount, 8)
        XCTAssertEqual(result?.finalText, polished)
        XCTAssertEqual(result?.processedText, polished)
        XCTAssertFalse(result?.llmFailed ?? true)
        XCTAssertEqual(result?.historyStatus, "voice_polish_success")
        XCTAssertTrue(recorder.values.contains("processing:\(polished)"))
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
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
        case .voicePolishUnavailable(let reason):
            return "voicePolishUnavailable:\(reason?.rawValue ?? "unknown")"
        case .finalized(let text, let injection):
            return "finalized:\(text):\(injection)"
        case .streamingInterrupted:
            return "streamingInterrupted"
        }
    }
}

private actor RecognitionSessionApplicationCaptureGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var hasStarted = false

    func capture() async -> String? {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ bundleIdentifier: String?) {
        continuation?.resume(returning: bundleIdentifier)
        continuation = nil
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
        if request.options.responseFormat == .jsonObject,
           let payload = try JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any] {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            if payload["draft_document"] != nil {
                let review = VoicePolishReviewerResult(verdict: "pass", issues: [])
                return LLMResponse(
                    text: String(decoding: try encoder.encode(review), as: UTF8.self),
                    model: config.model
                )
            }
            if let ledgerObject = payload["intent_ledger"] as? [String: Any],
               payload["current_draft_document"] == nil {
                let structure = ledgerObject["structure"] as? [String: Any]
                let unitIds = structure?["ordered_unit_ids"] as? [String] ?? ["u1"]
                let texts = Self.split(response, count: unitIds.count)
                let document = VoicePolishLedgerDraftDocument(fragments: zip(unitIds, texts).map {
                    VoicePolishLedgerDraftFragment(
                        id: "f_\($0.0)",
                        unitIds: [$0.0],
                        text: $0.1
                    )
                })
                return LLMResponse(
                    text: String(decoding: try encoder.encode(document), as: UTF8.self),
                    model: config.model
                )
            }
            if let allowedIDs = payload["allowed_fragment_ids"] as? [String] {
                let texts = Self.split(response, count: allowedIDs.count)
                let document = VoicePolishLedgerDraftDocument(fragments: zip(allowedIDs, texts).map {
                    let unitID = String($0.0.dropFirst(2))
                    return VoicePolishLedgerDraftFragment(
                        id: $0.0,
                        unitIds: [unitID],
                        text: $0.1
                    )
                })
                return LLMResponse(
                    text: String(decoding: try encoder.encode(document), as: UTF8.self),
                    model: config.model
                )
            }
            let sourceSpans = payload["source_spans"] as? [[String: Any]] ?? []
            let sourceLength = sourceSpans.compactMap { $0["text"] as? String }
                .reduce(0) { $0 + $1.count }
            let units = sourceSpans.enumerated().compactMap { index, span -> VoicePolishLedgerUnit? in
                guard let spanID = span["id"] as? String,
                      let text = span["text"] as? String else { return nil }
                return VoicePolishLedgerUnit(
                    id: "u\(index + 1)",
                    kind: "claim",
                    deliveryRole: "recipient_content",
                    finalMeaning: text,
                    sourceSpanIds: [spanID],
                    status: "keep",
                    modality: "confirmed",
                    exactTokens: [],
                    surfaceTokens: []
                )
            }
            let cues = payload["required_logic_cues"] as? [[String: Any]] ?? []
            let conditionals = cues.compactMap { cue -> VoicePolishLedgerConditional? in
                guard let cueID = cue["id"] as? String,
                      let cueSpanIDs = cue["source_span_ids"] as? [String],
                      let operatorKind = cue["operator_kind"] as? String,
                      !cueSpanIDs.isEmpty else { return nil }
                return VoicePolishLedgerConditional(
                    id: "c-\(cueID)",
                    cueIds: [cueID],
                    operatorKind: operatorKind,
                    condition: VoicePolishLedgerCondition(
                        subject: "来源条件",
                        predicate: "条件成立",
                        polarity: true,
                        sourceSpanIds: cueSpanIDs
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: "执行来源要求",
                        polarity: true,
                        sourceSpanIds: cueSpanIDs
                    )]
                )
            }
            let ledger = VoicePolishIntentLedger(
                audience: [],
                units: units,
                corrections: [],
                conditionals: conditionals,
                technicalTokenMappings: [],
                dictatedSymbolMappings: [],
                contextMappings: [],
                structure: VoicePolishLedgerStructure(
                    kind: sourceLength > 80 ? "paragraphs" : "sentence",
                    orderedUnitIds: units.map(\.id)
                )
            )
            return LLMResponse(
                text: String(decoding: try encoder.encode(ledger), as: UTF8.self),
                model: config.model
            )
        }
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

    private static func split(_ text: String, count: Int) -> [String] {
        guard count > 1 else { return [text] }
        let characters = Array(text)
        guard characters.count >= count else { return Array(repeating: text, count: count) }
        return (0..<count).map { index in
            let lower = characters.count * index / count
            let upper = characters.count * (index + 1) / count
            return String(characters[lower..<upper])
        }
    }
}

private actor RecognitionSessionScriptedVoicePolishLLM: LLMClient {
    private var responses: [String]
    private var requests: [LLMRequest] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
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

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }
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
