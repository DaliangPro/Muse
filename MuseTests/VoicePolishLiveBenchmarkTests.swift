import XCTest
@testable import Muse

final class VoicePolishLiveBenchmarkTests: XCTestCase {
    func testExplicitLiveProviderBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MUSE_VOICE_POLISH_LIVE"] == "1" else {
            throw XCTSkip("设置 MUSE_VOICE_POLISH_LIVE=1 后才运行真实 Provider Benchmark")
        }
        guard let config = KeychainService.loadLLMConfig() else {
            XCTFail("当前 LLM Provider 没有可用配置")
            return
        }
        let provider = KeychainService.selectedLLMProvider
        let client = LLMProviderRegistry.makeClient(for: provider)
        let requestedLimit = Int(environment["MUSE_VOICE_POLISH_LIVE_LIMIT"] ?? "30") ?? 30
        let fixtures = Array(VoicePolishFixtureCatalog.all.prefix(min(max(1, requestedLimit), 94)))
        var cases: [LiveCaseReport] = []

        for fixture in fixtures {
            let request = VoicePolishRequest(
                input: VoiceInputEnvelope(
                    providerFinalText: fixture.sourceText,
                    segments: fixture.segments,
                    durationMs: 3_000,
                    provider: .volcano
                ),
                context: WritingContext(scene: fixture.scene),
                preferences: UserPolishPreferences(additionalRequirements: ""),
                qualityMode: .balanced
            )
            let started = ContinuousClock.now
            let result = await VoicePolishPipeline(client: client, config: config).process(request)
            let elapsed = ContinuousClock.now - started
            let outputFacts = ProtectedFactExtractor.extract(from: [RecognitionSegment(
                id: "output",
                text: result.text,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )])
            let canonical = Set(outputFacts.compactMap(\.canonicalValue))
            let preserved = fixture.mustPreserveCanonicalFacts.allSatisfy(canonical.contains)
            let supersededRetained = fixture.supersededCanonicalFacts.contains(where: canonical.contains)
            let maximumBudget = result.executedRoute == .deep ? 3 : (result.executedRoute == .structured ? 2 : 1)
            XCTAssertLessThanOrEqual(result.llmAttemptCount, maximumBudget, fixture.id)
            cases.append(LiveCaseReport(
                fixtureID: fixture.id,
                detectedRoute: result.detectedRoute.rawValue,
                executedRoute: result.executedRoute.rawValue,
                callCount: result.llmAttemptCount,
                latencyMilliseconds: elapsed.components.seconds * 1_000
                    + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000),
                protectedFactsPassed: preserved,
                supersededFactRetained: supersededRetained,
                usedFallback: result.usedFallback,
                lengthRatio: Double(result.text.count) / Double(max(1, fixture.sourceText.count)),
                validationCodes: result.validationCodes.map(\.rawValue)
            ))
        }

        let report = LiveBenchmarkReport(
            runAt: Date(),
            provider: provider.rawValue,
            model: config.model,
            endpoint: config.baseURL,
            promptVersion: VoicePolishPrompts.version,
            fixtureCount: cases.count,
            protectedFactPassRate: Double(cases.filter(\.protectedFactsPassed).count) / Double(cases.count),
            supersededRetentionRate: Double(cases.filter(\.supersededFactRetained).count) / Double(cases.count),
            fallbackRate: Double(cases.filter(\.usedFallback).count) / Double(cases.count),
            cases: cases
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        let outputPath = environment["MUSE_VOICE_POLISH_LIVE_REPORT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("muse-voice-polish-live-report.json").path
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Voice Polish Live Benchmark 报告：\(outputPath)")
    }
}

private struct LiveCaseReport: Encodable {
    let fixtureID: String
    let detectedRoute: String
    let executedRoute: String
    let callCount: Int
    let latencyMilliseconds: Int64
    let protectedFactsPassed: Bool
    let supersededFactRetained: Bool
    let usedFallback: Bool
    let lengthRatio: Double
    let validationCodes: [String]
}

private struct LiveBenchmarkReport: Encodable {
    let runAt: Date
    let provider: String
    let model: String
    let endpoint: String
    let promptVersion: Int
    let fixtureCount: Int
    let protectedFactPassRate: Double
    let supersededRetentionRate: Double
    let fallbackRate: Double
    let cases: [LiveCaseReport]
}
