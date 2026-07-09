import Foundation
import os

struct TimedValue<T: Sendable>: Sendable {
    let value: T?
    let timedOut: Bool
}

enum AsyncTimeout {
    /// Run a closure with a hard deadline.
    /// Returns false if the operation throws or exceeds the deadline.
    static func run(
        _ duration: Duration,
        operation: @Sendable @escaping () async throws -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let operationTask = Task.detached {
                let ok: Bool
                do {
                    try await operation()
                    ok = true
                } catch {
                    ok = false
                }
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: ok)
                }
            }
            Task.detached {
                try? await Task.sleep(for: duration)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    operationTask.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Run an async value producer with a hard deadline（REPAIR_PLAN J12）。
    /// 超时返回 `TimedValue(value: nil, timedOut: true)` 并取消底层任务。
    static func asyncValue<T: Sendable>(
        _ duration: Duration,
        operation: @Sendable @escaping () async -> T?
    ) async -> TimedValue<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<TimedValue<T>, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let operationTask = Task.detached {
                let value = await operation()
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: TimedValue(value: value, timedOut: false))
                }
            }
            Task.detached {
                try? await Task.sleep(for: duration)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    operationTask.cancel()
                    continuation.resume(returning: TimedValue(value: nil, timedOut: true))
                }
            }
        }
    }

    /// Run a synchronous value loader off-actor with a hard deadline.
    static func value<T: Sendable>(
        _ duration: Duration,
        operation: @Sendable @escaping () -> T?
    ) async -> TimedValue<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<TimedValue<T>, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let operationTask = Task.detached(priority: .userInitiated) {
                let value = operation()
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: TimedValue(value: value, timedOut: false))
                }
            }
            Task.detached {
                try? await Task.sleep(for: duration)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    operationTask.cancel()
                    continuation.resume(returning: TimedValue(value: nil, timedOut: true))
                }
            }
        }
    }
}
