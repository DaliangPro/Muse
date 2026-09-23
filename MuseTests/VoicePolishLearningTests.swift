import XCTest
@testable import Muse

final class VoicePolishLearningTests: XCTestCase {
    func testProfileRequiresMinimumSamplesAndUsesSceneWeighting() {
        let two = makeRecords(count: 2, scene: .email, corrected: "您好，请确认，谢谢。")
        XCTAssertNil(StyleProfileUpdater.mergedProfile(from: two, scene: .email))

        let sceneOnly = makeRecords(count: 3, scene: .email, corrected: "您好，请确认，谢谢。")
        let sceneProfile = StyleProfileUpdater.mergedProfile(from: sceneOnly, scene: .email)
        XCTAssertEqual(sceneProfile?.sampleCount, 3)
        XCTAssertGreaterThan(sceneProfile?.formality ?? 0, 0)

        let global = makeRecords(count: 5, scene: .document, corrected: "请确认，谢谢。")
        let merged = StyleProfileUpdater.mergedProfile(
            from: global + sceneOnly,
            scene: .email
        )
        XCTAssertEqual(merged?.sampleCount, 11)
        XCTAssertLessThanOrEqual(abs(merged?.formality ?? 0), 0.1)
    }

    func testEachStyleSampleContributionIsClampedAndRecentSamplesHaveMoreWeight() {
        let old = correction(
            id: "old",
            date: Date(timeIntervalSince1970: 1),
            scene: .chat,
            generated: String(repeating: "很长", count: 100),
            corrected: "短"
        )
        let recent = correction(
            id: "recent",
            date: Date(timeIntervalSince1970: 2),
            scene: .chat,
            generated: "短",
            corrected: String(repeating: "很长", count: 100)
        )
        let profile = StyleProfileUpdater.profile(from: [old, recent])

        XCTAssertLessThan(profile.brevity, 0)
        XCTAssertLessThanOrEqual(abs(profile.brevity), 0.1)
    }

    func testExplicitCorrectionProducesCandidateImmediatelyAndSupportsEvidenceThreshold() {
        let once = [correction(
            id: "1",
            date: Date(),
            scene: .code,
            generated: "使用 Kubernetez 部署",
            corrected: "使用 Kubernetes 部署"
        )]
        let immediate = StyleProfileUpdater.lexiconCandidates(from: once)
        XCTAssertEqual(immediate.count, 1)
        XCTAssertEqual(immediate[0].alias, "Kubernetez")
        XCTAssertEqual(immediate[0].canonical, "Kubernetes")
        XCTAssertEqual(immediate[0].occurrenceCount, 1)
        XCTAssertTrue(StyleProfileUpdater.lexiconCandidates(
            from: once,
            minimumOccurrences: 2
        ).isEmpty)

        let candidates = StyleProfileUpdater.lexiconCandidates(from: once + [correction(
            id: "2",
            date: Date(),
            scene: .code,
            generated: "检查 Kubernetez 集群",
            corrected: "检查 Kubernetes 集群"
        )], minimumOccurrences: 2)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].alias, "Kubernetez")
        XCTAssertEqual(candidates[0].canonical, "Kubernetes")
        XCTAssertEqual(candidates[0].occurrenceCount, 2)
    }

    func testAutomaticLexiconCandidateSupportsManyTokensToOneCanonicalTerm() {
        XCTAssertEqual(
            TerminologyCorrectionExtractor.candidates(
                generatedText: "我正在用 Type less 写这段话",
                correctedText: "我正在用 Typeless 写这段话"
            ),
            [TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless")]
        )
        let record = correction(
            id: "typeless",
            date: Date(),
            scene: .chat,
            generated: "我正在用 Type less 写这段话",
            corrected: "我正在用 Typeless 写这段话"
        )

        let candidates = StyleProfileUpdater.lexiconCandidates(from: [record])

        XCTAssertEqual(candidates, [AutomaticLexiconCandidate(
            alias: "Type less",
            canonical: "Typeless",
            occurrenceCount: 1
        )])
    }

    func testTerminologyAndStyleLearningAuthorizationsAreIndependent() {
        let terminologyOnly = (0..<5).map { index in
            correction(
                id: "term-\(index)",
                date: Date(timeIntervalSince1970: Double(index)),
                scene: .chat,
                generated: "使用 Type less",
                corrected: "使用 Typeless",
                learnStyle: false,
                learnTerminology: true
            )
        }
        XCTAssertNil(StyleProfileUpdater.mergedProfile(from: terminologyOnly, scene: .chat))
        XCTAssertEqual(
            StyleProfileUpdater.lexiconCandidates(from: terminologyOnly).first?.canonical,
            "Typeless"
        )

        let styleOnly = correction(
            id: "style-only",
            date: Date(),
            scene: .chat,
            generated: "使用 Type less",
            corrected: "使用 Typeless",
            learnStyle: true,
            learnTerminology: false
        )
        XCTAssertTrue(StyleProfileUpdater.lexiconCandidates(from: [styleOnly]).isEmpty)
    }

    func testPostInjectionLearningExtractsInternalCorrection() {
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "我正在用 Type less 写这段话",
            prefix: "前文：",
            suffix: "；后文",
            windowText: "前文：我正在用 Typeless 写这段话；后文",
            caretOffset: nil
        )

        XCTAssertEqual(candidate, "我正在用 Typeless 写这段话")
        XCTAssertEqual(
            TerminologyCorrectionExtractor.candidates(
                generatedText: "我正在用 Type less 写这段话",
                correctedText: candidate ?? ""
            ),
            [TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless")]
        )
    }

    func testPostInjectionLearningIgnoresPureAppendedContent() {
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "这段文字已经完成。",
            prefix: "",
            suffix: "",
            windowText: "这段文字已经完成。我继续输入新的内容。",
            caretOffset: ("这段文字已经完成。我继续输入新的内容。" as NSString).length
        )

        XCTAssertNil(candidate)
    }

    func testPostInjectionLearningKeepsWholeCorrectedTextAtFieldEnd() {
        let corrected = "餐饮品牌是食其家。"
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "餐饮品牌是食奇家。",
            prefix: "已有内容 ",
            suffix: "",
            windowText: "已有内容 \(corrected)",
            // 模拟用户改完中间词后，真实光标仍停在“食其家”后；生产读取会用
            // 窗口末尾作为本次成稿边界，避免误删最后的句号。
            caretOffset: ("已有内容 \(corrected)" as NSString).length
        )

        XCTAssertEqual(candidate, corrected)
    }

    func testPostInjectionCorrectionPersistsHistoryAndTerminologyAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseAutoLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "MuseAutoLearningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        try HotwordStorage.saveBuiltin([], context: context)
        try SnippetStorage.saveBuiltin([], context: context)
        _ = try TerminologyRepository.migrateIfNeeded(context: context)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)
        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)

        let historyStore = HistoryStore(
            path: directory.appendingPathComponent("history.db").path
        )
        await historyStore.insert(HistoryRecord(
            id: "history-auto-learning",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "我正在用 Type less 写这段话",
            processingMode: "语音润色",
            processedText: "我正在用 Type less 写这段话",
            finalText: "我正在用 Type less 写这段话",
            status: "voice_polish_success",
            characterCount: 20
        ))
        let monitor = PostInjectionEditLearningMonitor(
            coordinator: TerminologyHistoryTransactionCoordinator(context: context),
            settingsContext: context
        )

        let didRecord = await monitor.recordCorrection(
            originalText: "我正在用 Type less 写这段话",
            correctedText: "我正在用 Typeless 写这段话",
            historyID: "history-auto-learning",
            historyStore: historyStore
        )

        XCTAssertTrue(didRecord)
        let corrections = try await historyStore.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].correctedText, "我正在用 Typeless 写这段话")
        XCTAssertTrue(corrections[0].learnStyle)
        XCTAssertTrue(corrections[0].learnTerminology)
        let terminology = TerminologyRepository.load(context: context)
        XCTAssertTrue(terminology.entries.contains { entry in
            entry.canonicalText == "Typeless"
                && entry.aliases.contains { $0.text == "Type less" }
        })
    }

    func testDisabledPersonalizationOmitsStyleProfileFromPayload() throws {
        let request = makeRequest(styleProfile: nil)
        let payload = try VoicePolishPrompts.payload(
            for: request,
            sourceFacts: [],
            deepDeferred: false
        )
        XCTAssertFalse(payload.contains("style_profile"))

        let enabled = makeRequest(styleProfile: StyleProfile(
            sampleCount: 5,
            brevity: 0.1,
            formality: 0,
            paragraphing: 0,
            listPreference: 0,
            punctuationDensity: 0
        ))
        let enabledPayload = try VoicePolishPrompts.payload(
            for: enabled,
            sourceFacts: [],
            deepDeferred: false
        )
        XCTAssertTrue(enabledPayload.contains("style_profile"))
        XCTAssertFalse(enabledPayload.contains("source_text"))
    }

    private func makeRecords(
        count: Int,
        scene: WritingScene,
        corrected: String
    ) -> [VoicePolishCorrectionRecord] {
        (0..<count).map { index in
            correction(
                id: "\(scene.rawValue)-\(index)",
                date: Date(timeIntervalSince1970: Double(index)),
                scene: scene,
                generated: "确认",
                corrected: corrected
            )
        }
    }

    private func correction(
        id: String,
        date: Date,
        scene: WritingScene,
        generated: String,
        corrected: String,
        learnStyle: Bool = true,
        learnTerminology: Bool = true
    ) -> VoicePolishCorrectionRecord {
        VoicePolishCorrectionRecord(
            id: id,
            historyID: "history-\(id)",
            createdAt: date,
            scene: scene,
            sourceText: "原始口述",
            generatedText: generated,
            correctedText: corrected,
            learnStyle: learnStyle,
            learnTerminology: learnTerminology
        )
    }

    private func makeRequest(styleProfile: StyleProfile?) -> VoicePolishRequest {
        let segment = RecognitionSegment(
            id: "s1",
            text: "请确认。",
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: segment.text,
                segments: [segment],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(),
            preferences: UserPolishPreferences(
                additionalRequirements: "",
                styleProfile: styleProfile
            ),
            qualityMode: .balanced
        )
    }
}
