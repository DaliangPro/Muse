import Foundation
import os

enum VoicePolishPerformanceOutcome: String, Codable, Sendable, Equatable {
    case success
    case fallback
    case canonicalExit
    case setupFailure
}

struct VoicePolishPerformanceMeasurement: Sendable, Equatable {
    let outcome: VoicePolishPerformanceOutcome
    let route: VoicePolishRoute?
    let llmAttemptCount: Int

    init(
        outcome: VoicePolishPerformanceOutcome,
        route: VoicePolishRoute? = nil,
        llmAttemptCount: Int = 0
    ) {
        self.outcome = outcome
        self.route = route
        self.llmAttemptCount = max(0, llmAttemptCount)
    }

    init(result: VoicePolishResult) {
        self.init(
            outcome: result.failureReason == .setupFailed
                ? .setupFailure
                : (result.usedFallback ? .fallback : .success),
            route: result.executedRoute,
            llmAttemptCount: result.llmAttemptCount
        )
    }
}

struct VoicePolishPerformanceSample: Codable, Sendable, Equatable {
    let recordedAt: Date
    /// setup failure / 提前使用 canonical 时可能尚未完成路由判断。
    let route: VoicePolishRoute?
    let latencyMilliseconds: Int
    let llmAttemptCount: Int
    let usedRepair: Bool
    let usedFallback: Bool
    /// optional 用于兼容已经写入的 v1 样本；nil 时由 usedFallback 推断。
    let outcome: VoicePolishPerformanceOutcome?

    var resolvedOutcome: VoicePolishPerformanceOutcome {
        outcome ?? (usedFallback ? .fallback : .success)
    }
}

struct VoicePolishRoutePerformanceSummary: Sendable, Equatable {
    let route: VoicePolishRoute
    let sampleCount: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
}

struct VoicePolishPerformanceSummary: Sendable, Equatable {
    let sampleCount: Int
    let singleCallRate: Double
    let repairRate: Double
    let fallbackRate: Double
    let routes: [VoicePolishRoutePerformanceSummary]
}

/// 仅保存最近的工程指标，不保存识别或润色正文。
enum VoicePolishPerformanceStore {
    static let maximumSampleCount = 200
    static let minimumVisibleSampleCount = 10

    private static let defaultsKey = "muse_voicePolishPerformanceSamples_v1"
    private static let lock = OSAllocatedUnfairLock(initialState: ())

    /// UserDefaults 的读写本身是线程安全的；包装只用于向 Swift 6 明确这一点，
    /// 实际的读-改-写序列仍由上面的 unfair lock 串行化。
    private struct SendableDefaults: @unchecked Sendable {
        let value: UserDefaults
    }

    static func record(
        result: VoicePolishResult,
        latencyMilliseconds: Int,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        record(
            measurement: VoicePolishPerformanceMeasurement(result: result),
            latencyMilliseconds: latencyMilliseconds,
            recordedAt: recordedAt,
            defaults: defaults
        )
    }

    static func record(
        measurement: VoicePolishPerformanceMeasurement,
        latencyMilliseconds: Int,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let baseAttemptCount = measurement.route == .deep ? 2 : 1
        let sample = VoicePolishPerformanceSample(
            recordedAt: recordedAt,
            route: measurement.route,
            latencyMilliseconds: max(0, latencyMilliseconds),
            llmAttemptCount: measurement.llmAttemptCount,
            usedRepair: measurement.route != nil
                && measurement.llmAttemptCount > baseAttemptCount,
            usedFallback: measurement.outcome == .fallback
                || measurement.outcome == .setupFailure,
            outcome: measurement.outcome
        )
        let storage = SendableDefaults(value: defaults)
        lock.withLock { _ in
            var values = loadUnlocked(defaults: storage.value)
            values.append(sample)
            if values.count > maximumSampleCount {
                values.removeFirst(values.count - maximumSampleCount)
            }
            guard let data = try? JSONEncoder().encode(values) else { return }
            storage.value.set(data, forKey: defaultsKey)
        }
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .voicePolishPerformanceDidChange,
                object: nil
            )
        }
    }

    static func samples(defaults: UserDefaults = .standard) -> [VoicePolishPerformanceSample] {
        let storage = SendableDefaults(value: defaults)
        return lock.withLock { _ in loadUnlocked(defaults: storage.value) }
    }

    static func summary(
        minimumSampleCount: Int = minimumVisibleSampleCount,
        defaults: UserDefaults = .standard
    ) -> VoicePolishPerformanceSummary? {
        let values = samples(defaults: defaults)
        guard values.count >= max(1, minimumSampleCount) else { return nil }
        let count = Double(values.count)
        let routeSummaries = VoicePolishRoute.allCasesForMetrics.compactMap { route -> VoicePolishRoutePerformanceSummary? in
            let latencies = values.filter { $0.route == route }.map(\.latencyMilliseconds).sorted()
            guard !latencies.isEmpty else { return nil }
            return VoicePolishRoutePerformanceSummary(
                route: route,
                sampleCount: latencies.count,
                p50Milliseconds: percentile(0.50, values: latencies),
                p95Milliseconds: percentile(0.95, values: latencies)
            )
        }
        return VoicePolishPerformanceSummary(
            sampleCount: values.count,
            singleCallRate: Double(values.filter {
                $0.resolvedOutcome == .success && $0.llmAttemptCount == 1
            }.count) / count,
            repairRate: Double(values.filter(\.usedRepair).count) / count,
            fallbackRate: Double(values.filter {
                $0.resolvedOutcome == .fallback || $0.resolvedOutcome == .setupFailure
            }.count) / count,
            routes: routeSummaries
        )
    }

    static func reset(defaults: UserDefaults = .standard) {
        let storage = SendableDefaults(value: defaults)
        lock.withLock { _ in storage.value.removeObject(forKey: defaultsKey) }
    }

    private static func loadUnlocked(defaults: UserDefaults) -> [VoicePolishPerformanceSample] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([VoicePolishPerformanceSample].self, from: data)
        else { return [] }
        return Array(values.suffix(maximumSampleCount))
    }

    private static func percentile(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(values.count - 1, rank - 1)]
    }
}

private extension VoicePolishRoute {
    static let allCasesForMetrics: [VoicePolishRoute] = [.fast, .structured, .deep]
}

extension Notification.Name {
    static let voicePolishPerformanceDidChange = Notification.Name(
        "MuseVoicePolishPerformanceDidChange"
    )
}
