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

    func testAutomaticLexiconCandidatesNeedRepeatedExplicitCorrections() {
        let once = [correction(
            id: "1",
            date: Date(),
            scene: .code,
            generated: "使用 Kubernetez 部署",
            corrected: "使用 Kubernetes 部署"
        )]
        XCTAssertTrue(StyleProfileUpdater.lexiconCandidates(from: once).isEmpty)

        let candidates = StyleProfileUpdater.lexiconCandidates(from: once + [correction(
            id: "2",
            date: Date(),
            scene: .code,
            generated: "检查 Kubernetez 集群",
            corrected: "检查 Kubernetes 集群"
        )])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].alias, "Kubernetez")
        XCTAssertEqual(candidates[0].canonical, "Kubernetes")
        XCTAssertEqual(candidates[0].occurrenceCount, 2)
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
        corrected: String
    ) -> VoicePolishCorrectionRecord {
        VoicePolishCorrectionRecord(
            id: id,
            historyID: "history-\(id)",
            createdAt: date,
            scene: scene,
            sourceText: "原始口述",
            generatedText: generated,
            correctedText: corrected
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
