import Foundation

/// RecognitionSession 只依赖这组采集能力，测试可用内存 spy 验证跨会话资源所有权。
protocol AudioCaptureControlling: AnyObject, Sendable {
    func warmUp()
    func setAudioHandlers(
        onChunk: ((Data) -> Void)?,
        onLevel: ((Float) -> Void)?
    )
    func setAudioChunkHandler(_ handler: ((Data) -> Void)?)
    func clearAudioHandlers()
    func start(timeout: Duration) async throws
    func stop()
    func getRecordedAudio() -> Data
}

extension AudioCaptureControlling {
    func start() async throws {
        try await start(timeout: AudioCaptureEngine.startTimeout)
    }
}

extension AudioCaptureEngine: AudioCaptureControlling {}

/// 注入引擎的最小行为边界，避免竞态测试触碰系统剪贴板或辅助功能。
protocol TextInjecting: AnyObject, Sendable {
    var preserveClipboard: Bool { get set }
    func inject(_ text: String) -> InjectionOutcome
}

extension TextInjectionEngine: TextInjecting {}
