import XCTest
@testable import Muse

final class VoicePolishPerformanceStoreTests: XCTestCase {
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
        XCTAssertEqual(summary.singleCallRate, 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(summary.repairRate, 1.0 / 6.0, accuracy: 0.0001)
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

    func testSummaryRecordsEveryOutcomeAndDoesNotCountFallbackAsSingleCall() throws {
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
        XCTAssertEqual(summary.singleCallRate, 0)
        XCTAssertEqual(summary.fallbackRate, 2.0 / 3.0, accuracy: 0.0001)
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
