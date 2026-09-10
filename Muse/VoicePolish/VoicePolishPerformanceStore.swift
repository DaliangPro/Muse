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
    /// 旧记录没有产品档位，保持 nil，不根据历史路由猜测轻度或标准。
    var qualityMode: VoicePolishQualityMode? = nil

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
    /// 最近保存的全部正式语音润色会话，包含主动使用 canonical 和初始化失败。
    let sampleCount: Int
    /// 真正完成过至少一次 LLM 调用且未由用户主动提前结束的会话。
    let llmRequestSampleCount: Int
    /// 系统自动处理的会话；主动使用 canonical 不参与回退率分母。
    let automaticSampleCount: Int
    /// 尚无实际模型请求时为 nil，避免把 0/0 错写成 0%。
    let singleCallRate: Double?
    /// 未追加修复且成功成稿的自动会话占比；标准的正常生成加复核计为无需修复。
    let unrepairedSuccessRate: Double
    /// 尚无实际模型请求时为 nil，避免把 0/0 错写成 0%。
    let repairRate: Double?
    let fallbackRate: Double
    let routes: [VoicePolishRoutePerformanceSummary]
    let p50Milliseconds: Int
    let p95Milliseconds: Int
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
        qualityMode: VoicePolishQualityMode? = nil,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        record(
            measurement: VoicePolishPerformanceMeasurement(result: result),
            latencyMilliseconds: latencyMilliseconds,
            qualityMode: qualityMode,
            recordedAt: recordedAt,
            defaults: defaults
        )
    }

    static func record(
        measurement: VoicePolishPerformanceMeasurement,
        latencyMilliseconds: Int,
        qualityMode: VoicePolishQualityMode? = nil,
        recordedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        // 标准润色的生成与独立复核都是正常流程，不把第二次调用误报成修复。
        let baseAttemptCount = qualityMode == .standard || measurement.route == .deep ? 2 : 1
        let sample = VoicePolishPerformanceSample(
            recordedAt: recordedAt,
            route: measurement.route,
            latencyMilliseconds: max(0, latencyMilliseconds),
            llmAttemptCount: measurement.llmAttemptCount,
            usedRepair: measurement.route != nil
                && measurement.llmAttemptCount > baseAttemptCount,
            usedFallback: measurement.outcome == .fallback
                || measurement.outcome == .setupFailure,
            outcome: measurement.outcome,
            qualityMode: qualityMode
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

    static func automaticSampleCount(
        qualityMode: VoicePolishQualityMode? = nil,
        defaults: UserDefaults = .standard
    ) -> Int {
        samples(defaults: defaults).filter {
            $0.resolvedOutcome != .canonicalExit && (qualityMode == nil || $0.qualityMode == qualityMode)
        }.count
    }

    static func summary(
        minimumSampleCount: Int = minimumVisibleSampleCount,
        qualityMode: VoicePolishQualityMode? = nil,
        defaults: UserDefaults = .standard
    ) -> VoicePolishPerformanceSummary? {
        let values = samples(defaults: defaults).filter { qualityMode == nil || $0.qualityMode == qualityMode }
        let automaticValues = values.filter { $0.resolvedOutcome != .canonicalExit }
        guard automaticValues.count >= max(1, minimumSampleCount) else { return nil }
        let llmRequestValues = automaticValues.filter { $0.llmAttemptCount > 0 }
        let routeSummaries = VoicePolishRoute.allCasesForMetrics.compactMap { route -> VoicePolishRoutePerformanceSummary? in
            let latencies = automaticValues.filter { $0.route == route }
                .map(\.latencyMilliseconds)
                .sorted()
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
            llmRequestSampleCount: llmRequestValues.count,
            automaticSampleCount: automaticValues.count,
            singleCallRate: rate(
                numerator: llmRequestValues.filter { $0.llmAttemptCount == 1 }.count,
                denominator: llmRequestValues.count
            ),
            unrepairedSuccessRate: rate(
                numerator: automaticValues.filter { $0.resolvedOutcome == .success && !$0.usedRepair }.count,
                denominator: automaticValues.count
            ) ?? 0,
            repairRate: rate(
                numerator: llmRequestValues.filter(\.usedRepair).count,
                denominator: llmRequestValues.count
            ),
            fallbackRate: rate(
                numerator: automaticValues.filter {
                $0.resolvedOutcome == .fallback || $0.resolvedOutcome == .setupFailure
                }.count,
                denominator: automaticValues.count
            ) ?? 0,
            routes: routeSummaries,
            p50Milliseconds: percentile(0.50, values: automaticValues.map(\.latencyMilliseconds).sorted()),
            p95Milliseconds: percentile(0.95, values: automaticValues.map(\.latencyMilliseconds).sorted())
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

    private static func rate(numerator: Int, denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
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
