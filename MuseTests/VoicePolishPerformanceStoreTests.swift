import XCTest
@testable import Muse

final class VoicePolishPerformanceStoreTests: XCTestCase {
    func testModeSummariesDoNotMixLegacyLightAndStandardMeasurements() throws {
        let suiteName = "VoicePolishModePerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1), latencyMilliseconds: 50, defaults: defaults
        )
        for latency in [100, 200] {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1), latencyMilliseconds: latency,
                qualityMode: .light, defaults: defaults
            )
        }
        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 2), latencyMilliseconds: 900,
            qualityMode: .standard, defaults: defaults
        )
        let light = try XCTUnwrap(VoicePolishPerformanceStore.summary(
            minimumSampleCount: 1, qualityMode: .light, defaults: defaults
        ))
        let standard = try XCTUnwrap(VoicePolishPerformanceStore.summary(
            minimumSampleCount: 1, qualityMode: .standard, defaults: defaults
        ))
        XCTAssertEqual(light.sampleCount, 2)
        XCTAssertEqual(light.p50Milliseconds, 100)
        XCTAssertEqual(light.p95Milliseconds, 200)
        XCTAssertEqual(standard.sampleCount, 1)
        XCTAssertEqual(standard.p50Milliseconds, 900)
        XCTAssertEqual(standard.repairRate, 0)
        XCTAssertEqual(standard.unrepairedSuccessRate, 1)
        XCTAssertEqual(light.unrepairedSuccessRate, 1)
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(qualityMode: .light, defaults: defaults), 2)
        XCTAssertNil(VoicePolishPerformanceStore.samples(defaults: defaults).first?.qualityMode)
    }

    func testOldPerformanceJSONRemainsReadableWithoutInventingAMode() throws {
        let sample = try JSONDecoder().decode(VoicePolishPerformanceSample.self, from: Data(
            #"{"recordedAt":0,"route":"fast","latencyMilliseconds":123,"llmAttemptCount":1,"usedRepair":false,"usedFallback":false}"#.utf8
        ))
        XCTAssertEqual(sample.latencyMilliseconds, 123)
        XCTAssertEqual(sample.resolvedOutcome, .success)
        XCTAssertNil(sample.qualityMode)
    }

    func testSummaryUsesEndToEndLatencyAndSeparatesDeepBaseCallsFromRepair() throws {
        let suiteName = "VoicePolishPerformanceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for latency in [100, 200, 300, 400] {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1),
                latencyMilliseconds: latency,
                defaults: defaults
            )
        }
        VoicePolishPerformanceStore.record(
            result: result(route: .structured, attempts: 2),
            latencyMilliseconds: 500,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            result: result(route: .deep, attempts: 2),
            latencyMilliseconds: 900,
            defaults: defaults
        )

        let summary = try XCTUnwrap(
            VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults)
        )
        XCTAssertEqual(summary.sampleCount, 6)
        XCTAssertEqual(summary.llmRequestSampleCount, 6)
        XCTAssertEqual(summary.automaticSampleCount, 6)
        XCTAssertEqual(try XCTUnwrap(summary.singleCallRate), 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.repairRate), 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(summary.fallbackRate, 0)
        let fast = try XCTUnwrap(summary.routes.first { $0.route == .fast })
        XCTAssertEqual(fast.p50Milliseconds, 200)
        XCTAssertEqual(fast.p95Milliseconds, 400)
    }

    func testSummaryStaysHiddenUntilEnoughSamplesAndRetentionIsBounded() throws {
        let suiteName = "VoicePolishPerformanceRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1),
            latencyMilliseconds: 10,
            defaults: defaults
        )
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))

        for latency in 0..<(VoicePolishPerformanceStore.maximumSampleCount + 20) {
            VoicePolishPerformanceStore.record(
                result: result(route: .fast, attempts: 1),
                latencyMilliseconds: latency,
                defaults: defaults
            )
        }
        let samples = VoicePolishPerformanceStore.samples(defaults: defaults)
        XCTAssertEqual(samples.count, VoicePolishPerformanceStore.maximumSampleCount)
        XCTAssertEqual(samples.last?.latencyMilliseconds, VoicePolishPerformanceStore.maximumSampleCount + 19)
    }

    func testSummaryUsesOutcomeSpecificDenominators() throws {
        let suiteName = "VoicePolishPerformanceOutcomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(
                outcome: .fallback,
                route: .fast,
                llmAttemptCount: 1
            ),
            latencyMilliseconds: 100,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(
                outcome: .canonicalExit,
                route: .structured,
                llmAttemptCount: 1
            ),
            latencyMilliseconds: 200,
            defaults: defaults
        )
        VoicePolishPerformanceStore.record(
            measurement: VoicePolishPerformanceMeasurement(outcome: .setupFailure),
            latencyMilliseconds: 20,
            defaults: defaults
        )

        let samples = VoicePolishPerformanceStore.samples(defaults: defaults)
        XCTAssertEqual(samples.map(\.resolvedOutcome), [
            .fallback,
            .canonicalExit,
            .setupFailure,
        ])
        let summary = try XCTUnwrap(
            VoicePolishPerformanceStore.summary(minimumSampleCount: 1, defaults: defaults)
        )
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.llmRequestSampleCount, 1)
        XCTAssertEqual(summary.automaticSampleCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.singleCallRate), 1)
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertEqual(summary.unrepairedSuccessRate, 0)
        XCTAssertTrue(summary.routes.allSatisfy { $0.route != .structured })
    }

    func testSummaryDoesNotInventRatesWhenEverySessionUsesCanonicalExit() throws {
        let suiteName = "VoicePolishPerformanceCanonicalOnlyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for _ in 0..<VoicePolishPerformanceStore.minimumVisibleSampleCount {
            VoicePolishPerformanceStore.record(
                measurement: VoicePolishPerformanceMeasurement(
                    outcome: .canonicalExit,
                    route: .structured,
                    llmAttemptCount: 1
                ),
                latencyMilliseconds: 200,
                defaults: defaults
            )
        }

        XCTAssertEqual(
            VoicePolishPerformanceStore.samples(defaults: defaults).count,
            VoicePolishPerformanceStore.minimumVisibleSampleCount
        )
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(defaults: defaults), 0)
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))

        VoicePolishPerformanceStore.record(
            result: result(route: .fast, attempts: 1),
            latencyMilliseconds: 100,
            defaults: defaults
        )
        XCTAssertEqual(VoicePolishPerformanceStore.automaticSampleCount(defaults: defaults), 1)
        XCTAssertNil(VoicePolishPerformanceStore.summary(defaults: defaults))
    }

    func testSummaryShowsUnavailableLLMRatesWhenAutomaticSessionsNeverReachModel() throws {
        let suiteName = "VoicePolishPerformanceNoLLMTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for _ in 0..<VoicePolishPerformanceStore.minimumVisibleSampleCount {
            VoicePolishPerformanceStore.record(
                measurement: VoicePolishPerformanceMeasurement(outcome: .setupFailure),
                latencyMilliseconds: 20,
                defaults: defaults
            )
        }

        let summary = try XCTUnwrap(VoicePolishPerformanceStore.summary(defaults: defaults))
        XCTAssertEqual(summary.automaticSampleCount, VoicePolishPerformanceStore.minimumVisibleSampleCount)
        XCTAssertEqual(summary.llmRequestSampleCount, 0)
        XCTAssertNil(summary.singleCallRate)
        XCTAssertNil(summary.repairRate)
        XCTAssertEqual(summary.fallbackRate, 1)
        XCTAssertTrue(summary.routes.isEmpty)
    }

    private func result(
        route: VoicePolishRoute,
        attempts: Int,
        fallback: Bool = false
    ) -> VoicePolishResult {
        VoicePolishResult(
            text: "结果",
            detectedRoute: route,
            executedRoute: route,
            llmAttemptCount: attempts,
            validationCodes: [],
            usedFallback: fallback,
            failureReason: fallback ? .requestFailed : nil
        )
    }
}
