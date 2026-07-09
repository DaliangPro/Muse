@preconcurrency import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed
    case microphonePermissionDenied
    case noInputDevice
    case startTimedOut
    case startCancelled
    case systemStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return L("录音启动失败", "Failed to start recording")
        case .microphonePermissionDenied:
            return L("未授予麦克风权限", "Microphone permission not granted")
        case .noInputDevice:
            return L("找不到麦克风", "No microphone found")
        case .startTimedOut:
            return L("录音启动超时，请再试一次", "Recording startup timed out. Please try again.")
        case .startCancelled:
            return L("录音启动已取消", "Recording startup was cancelled.")
        case .systemStartFailed:
            return L("录音启动失败", "Failed to start recording")
        }
    }
}

struct AudioCaptureStartState: Sendable {
    private(set) var generation = 0

    mutating func nextToken() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

struct AudioCaptureIdleState: Sendable {
    private(set) var generation = 0

    mutating func nextToken() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

final class AudioCaptureEngine: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Static properties

    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1
    static let chunkDurationMs: Int = 200
    static let startTimeout: Duration = .seconds(8)
    static let idleCaptureRetentionSeconds: TimeInterval = 8
    static let samplesPerChunk: Int = Int(sampleRate * Double(chunkDurationMs) / 1000)
    static let chunkByteSize: Int = samplesPerChunk * MemoryLayout<Int16>.size
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    static func makePCMBuffer(from pcmData: Data) -> AVAudioPCMBuffer? {
        guard pcmData.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        guard let mData = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        pcmData.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: pcmData.count)
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(pcmData.count)
        return buffer
    }

    // MARK: - Public

    private var onAudioChunk: ((Data) -> Void)?
    private var onAudioLevel: ((Float) -> Void)?

    func setAudioHandlers(
        onChunk: ((Data) -> Void)?,
        onLevel: ((Float) -> Void)?
    ) {
        handlerLock.withLock {
            onAudioChunk = onChunk
            onAudioLevel = onLevel
        }
    }

    func setAudioChunkHandler(_ handler: ((Data) -> Void)?) {
        handlerLock.withLock {
            onAudioChunk = handler
        }
    }

    func clearAudioHandlers() {
        setAudioHandlers(onChunk: nil, onLevel: nil)
    }

    /// REPAIR_PLAN B8：整段录音的内存软上限（默认 30 分钟 PCM ≈ 57.6MB）。
    /// 超限即丢弃整段缓存并停止累积——批量兜底重识别本就只为常规时长设计，
    /// 超长会话的文本仍由流式结果保证。可注入小值供测试。
    var accumulatedAudioByteLimit = AudioCaptureEngine.defaultAccumulatedAudioByteLimit
    static let defaultAccumulatedAudioByteLimit =
        30 * 60 * Int(sampleRate) * MemoryLayout<Int16>.size

    // MARK: - Private

    private var captureSession: AVCaptureSession?
    private let stateLock = NSLock()
    private let bufferLock = NSLock()
    private let handlerLock = NSLock()
    private var buffer = Data()
    private var accumulatedAudio = Data()
    private var accumulatedAudioOverflowed = false
    private var converter: AVAudioConverter?
    private let outputQueue = DispatchQueue(label: "pro.daliang.muse.audiocapture")
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private let outputQueueTag: UInt8 = 1
    private var activeOutput: AVCaptureAudioDataOutput?
    private var idleCaptureSession: AVCaptureSession?
    private var idleCaptureOutput: AVCaptureAudioDataOutput?
    private var idleState = AudioCaptureIdleState()
    private var levelCounter = 0
    private var startState = AudioCaptureStartState()

    private enum StartOutcome: Sendable {
        case success
        case cancelled
        case converterCreationFailed
        case noInputDevice
        case failed(String)
    }

    // MARK: - Warm-up

    /// REPAIR_PLAN J11：由 stateLock 保护——warmUp 的读（调用线程）、warm-up 完成写
    /// （global queue）与 startWithAVCapture 写（actor 线程）三方并发，裸 Bool 是 UB
    private var isWarmedUp = false

    override init() {
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: outputQueueTag)
    }

    /// Pre-initialize the audio capture pipeline so the first real recording starts instantly.
    func warmUp() {
        guard !stateLock.withLock({ isWarmedUp }) else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AppLogger.log("[Audio] Warm-up skipped: microphone permission not granted")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else { return }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                session.startRunning()
                // Keep it alive briefly to fully initialize CoreAudio, then stop
                Thread.sleep(forTimeInterval: 0.3)
                session.stopRunning()
                self.stateLock.withLock { self.isWarmedUp = true }
                AppLogger.log("[Audio] Warm-up complete")
            } catch {
                AppLogger.log("[Audio] Warm-up failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Start / Stop

    func start(timeout: Duration = AudioCaptureEngine.startTimeout) async throws {
        let token = try prepareStart()

        let result: TimedValue<StartOutcome> = await AsyncTimeout.value(timeout) {
            self.startWithAVCapture(token: token)
        }

        if result.timedOut {
            invalidateStart(token)
            DebugFileLogger.log("audio engine start timeout after \(timeout)")
            throw AudioCaptureError.startTimedOut
        }

        switch result.value {
        case .success:
            return
        case .cancelled:
            throw AudioCaptureError.startCancelled
        case .converterCreationFailed:
            throw AudioCaptureError.converterCreationFailed
        case .noInputDevice:
            throw AudioCaptureError.noInputDevice
        case .failed(let message):
            throw AudioCaptureError.systemStartFailed(message)
        case .none:
            throw AudioCaptureError.startTimedOut
        }
    }

    private func prepareStart() throws -> Int {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Reset state
        bufferLock.lock()
        buffer = Data()
        accumulatedAudio = Data()
        accumulatedAudioOverflowed = false
        bufferLock.unlock()
        converter = nil

        return stateLock.withLock {
            startState.nextToken()
        }
    }

    private func invalidateStart(_ token: Int) {
        stateLock.withLock {
            guard startState.isCurrent(token) else { return }
            startState.invalidate()
        }
    }

    private func startWithAVCapture(token: Int) -> StartOutcome {
        if let idleCapture = takeIdleCaptureForReuse(token: token) {
            return reuseIdleCapture(idleCapture, token: token)
        }

        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            return .noInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failed(String(describing: error))
        }
        guard session.canAddInput(input) else {
            return .converterCreationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            output.setSampleBufferDelegate(nil, queue: nil)
            return .converterCreationFailed
        }
        session.addOutput(output)

        session.startRunning()
        let accepted = stateLock.withLock { () -> Bool in
            guard startState.isCurrent(token) else { return false }
            captureSession = session
            activeOutput = output
            isWarmedUp = true
            return true
        }
        guard accepted else {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            DebugFileLogger.log("audio engine late start discarded token=\(token)")
            return .cancelled
        }
        AppLogger.log("[Audio] Capture session started (AVCapture), device: \(device.localizedName)")
        return .success
    }

    func stop() {
        let current = stateLock.withLock { () -> (AVCaptureSession?, AVCaptureAudioDataOutput?) in
            startState.invalidate()
            let session = captureSession
            let output = activeOutput
            captureSession = nil
            activeOutput = nil
            return (session, output)
        }
        current.1?.setSampleBufferDelegate(nil, queue: nil)
        drainOutputQueue()
        flushRemaining()
        if let session = current.0 {
            parkIdleCapture(session: session, output: current.1)
        }
        bufferLock.lock()
        converter = nil
        bufferLock.unlock()
        clearAudioHandlers()
        levelCounter = 0
        AppLogger.log("[Audio] Capture session stopped")
    }

    private func takeIdleCaptureForReuse(token: Int) -> (session: AVCaptureSession, output: AVCaptureAudioDataOutput)? {
        stateLock.withLock {
            guard startState.isCurrent(token),
                  let session = idleCaptureSession,
                  let output = idleCaptureOutput,
                  session.isRunning
            else {
                return nil
            }
            idleCaptureSession = nil
            idleCaptureOutput = nil
            idleState.invalidate()
            return (session, output)
        }
    }

    private func reuseIdleCapture(
        _ idleCapture: (session: AVCaptureSession, output: AVCaptureAudioDataOutput),
        token: Int
    ) -> StartOutcome {
        let accepted = stateLock.withLock { () -> Bool in
            guard startState.isCurrent(token) else { return false }
            captureSession = idleCapture.session
            activeOutput = idleCapture.output
            isWarmedUp = true
            return true
        }
        guard accepted else {
            idleCapture.output.setSampleBufferDelegate(nil, queue: nil)
            idleCapture.session.stopRunning()
            DebugFileLogger.log("audio engine idle reuse cancelled token=\(token)")
            return .cancelled
        }

        idleCapture.output.setSampleBufferDelegate(self, queue: outputQueue)
        AppLogger.log("[Audio] Reused parked capture session")
        DebugFileLogger.log("audio engine reused parked session token=\(token)")
        return .success
    }

    private func parkIdleCapture(
        session: AVCaptureSession,
        output: AVCaptureAudioDataOutput?
    ) {
        guard session.isRunning, let output else {
            output?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            return
        }

        let parked = stateLock.withLock { () -> (token: Int, oldSession: AVCaptureSession?, oldOutput: AVCaptureAudioDataOutput?) in
            let oldSession = idleCaptureSession
            let oldOutput = idleCaptureOutput
            idleCaptureSession = session
            idleCaptureOutput = output
            return (idleState.nextToken(), oldSession, oldOutput)
        }
        parked.oldOutput?.setSampleBufferDelegate(nil, queue: nil)
        parked.oldSession?.stopRunning()

        let token = parked.token
        DebugFileLogger.log("audio engine parked session token=\(token)")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleCaptureRetentionSeconds) { [weak self] in
            self?.expireIdleCapture(token: token)
        }
    }

    private func expireIdleCapture(token: Int) {
        let expired = stateLock.withLock { () -> (AVCaptureSession?, AVCaptureAudioDataOutput?) in
            guard idleState.isCurrent(token) else { return (nil, nil) }
            let session = idleCaptureSession
            let output = idleCaptureOutput
            idleCaptureSession = nil
            idleCaptureOutput = nil
            idleState.invalidate()
            return (session, output)
        }
        expired.1?.setSampleBufferDelegate(nil, queue: nil)
        expired.0?.stopRunning()
        if expired.0 != nil {
            DebugFileLogger.log("audio engine idle session expired token=\(token)")
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let isActiveOutput = stateLock.withLock { activeOutput === output }
        guard isActiveOutput else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Emit audio level ~20 times/sec (every 3rd callback at typical 60Hz buffer rate)
        levelCounter += 1
        if levelCounter % 3 == 0, let onAudioLevel = currentAudioLevelHandler() {
            let level = Self.calculateLevel(from: pcmBuffer)
            onAudioLevel(level)
        }

        // Create or recreate converter when source format changes
        bufferLock.lock()
        let sourceFormat = pcmBuffer.format
        if converter == nil || converter?.inputFormat != sourceFormat {
            if converter != nil {
                AppLogger.log("[Audio] Input format changed, rebuilding converter: \(sourceFormat.description)")
            }
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            AppLogger.log("[Audio] Input format: \(sourceFormat.description)")
        }
        guard let conv = converter else {
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        convert(buffer: pcmBuffer, using: conv)
    }

    // MARK: - Internal

    private func convert(buffer pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * Self.sampleRate / pcmBuffer.format.sampleRate
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        nonisolated(unsafe) var hasData = true
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil else { return }

        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        let chunk = Data(bytes: mData, count: byteCount)

        ingest(chunk: chunk)
    }

    /// 转码后的统一入口：累积整段录音（带 B8 上限）+ 切块回调（B2 锁外调用）
    private func ingest(chunk: Data) {
        bufferLock.lock()
        var overflowJustHappened = false
        if !accumulatedAudioOverflowed {
            accumulatedAudio.append(chunk)
            if accumulatedAudio.count > accumulatedAudioByteLimit {
                // 超限：丢弃整段缓存并停止累积，批量兜底自动失效（getRecordedAudio 为空）
                accumulatedAudio = Data()
                accumulatedAudioOverflowed = true
                overflowJustHappened = true
            }
        }
        buffer.append(chunk)
        var fullChunks: [Data] = []
        while buffer.count >= Self.chunkByteSize {
            fullChunks.append(Data(buffer.prefix(Self.chunkByteSize)))
            buffer.removeFirst(Self.chunkByteSize)
        }
        bufferLock.unlock()
        let callback = currentAudioChunkHandler()
        if overflowJustHappened {
            AppLogger.log("[Audio] 录音超过内存上限（\(accumulatedAudioByteLimit) 字节），停止整段缓存，批量兜底对本次会话失效")
        }
        for chunk in fullChunks {
            callback?(chunk)
        }
    }

    #if DEBUG
    /// 测试入口：绕过采集设备直接灌入转码后的数据
    func ingestForTesting(_ chunk: Data) {
        ingest(chunk: chunk)
    }
    #endif

    /// Returns the full recorded PCM audio since the last start().
    func getRecordedAudio() -> Data {
        bufferLock.lock()
        let data = accumulatedAudio
        bufferLock.unlock()
        return data
    }

    /// RMS → normalized 0..1 level from float PCM buffer.
    private static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let ptr = channelData[0]
        var sum: Float = 0
        // Sample every 16th frame for efficiency (256 samples max)
        let stride = max(1, frames / 256)
        var count = 0
        var i = 0
        while i < frames {
            sum += ptr[i] * ptr[i]
            count += 1
            i += stride
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50dB..0dB → 0..1
        return max(0, min(1, (db + 50) / 50))
    }

    private func drainOutputQueue() {
        if DispatchQueue.getSpecific(key: outputQueueKey) == outputQueueTag {
            return  // already on outputQueue, skip to avoid deadlock
        }
        outputQueue.sync {}
    }

    private func flushRemaining() {
        bufferLock.lock()
        let remaining = buffer
        buffer = Data()
        bufferLock.unlock()

        if !remaining.isEmpty {
            currentAudioChunkHandler()?(remaining)
        }
    }

    private func currentAudioChunkHandler() -> ((Data) -> Void)? {
        handlerLock.withLock { onAudioChunk }
    }

    private func currentAudioLevelHandler() -> ((Float) -> Void)? {
        handlerLock.withLock { onAudioLevel }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)

        if let floatData = pcmBuffer.floatChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: floatData[0])
        } else if let int16Data = pcmBuffer.int16ChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: int16Data[0])
        } else {
            return nil
        }

        return pcmBuffer
    }
}
