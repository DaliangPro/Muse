import Foundation
import os

/// Manages downloading, verifying, and locating SherpaOnnx model files.
actor ModelManager {

    static let shared = ModelManager()

    private let logger = Logger(subsystem: "pro.daliang.muse.models", category: "ModelManager")

    // MARK: - Paths

    static var defaultModelsDir: String {
        AppPaths.support("models", isDirectory: true).path
    }

    private var modelsDir: String { Self.defaultModelsDir }

    // MARK: - Streaming Model Variants

    enum StreamingModel: String, CaseIterable, Sendable {
        case senseVoiceSmall = "sensevoice-small"

        var displayName: String {
            return L("SenseVoice 智能识别", "SenseVoice Smart")
        }

        var description: String {
            return L("阿里最新模型，中文准确率最高，支持中英粤日韩",
                     "Alibaba's latest, best Chinese accuracy, zh/en/yue/ja/ko")
        }

        var directoryName: String {
            return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        }

        var downloadURL: URL {
            let base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            return URL(string: base + directoryName + ".tar.bz2")!
        }

        var requiredFiles: [String] {
            return ["model.int8.onnx", "tokens.txt"]
        }

        /// Approximate download size in MB for UI display.
        var approximateSizeMB: Int {
            return 228
        }
    }

    // MARK: - SenseVoice Availability

    /// Whether the SenseVoice model is bundled in the app (full DMG version).
    nonisolated static var isSenseVoiceBundled: Bool {
        // Check if sensevoice-server exists in app bundle
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("sensevoice-server"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return true
        }
        // Dev mode: check if sensevoice-server dir exists in project
        let home = NSHomeDirectory()
        let devPath = (home as NSString).appendingPathComponent("projects/muse/sensevoice-server/server.py")
        return FileManager.default.fileExists(atPath: devPath)
    }

    // MARK: - Auxiliary Model Types (punctuation, offline, etc.)

    enum AuxModelType: String, CaseIterable, Sendable {
        case punctuation       = "punctuation"

        var displayName: String {
            switch self {
            case .punctuation:       return L("标点恢复模型", "Punctuation")
            }
        }

        var directoryName: String {
            switch self {
            case .punctuation:       return "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
            }
        }

        var downloadURL: URL {
            switch self {
            case .punctuation:
                return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/" + directoryName + ".tar.bz2")!
            }
        }

        /// Whether this model is a single file download (not a tar.bz2 archive).
        var isSingleFile: Bool { false }

        var requiredFiles: [String] {
            switch self {
            case .punctuation:       return ["model.onnx"]
            }
        }

        var approximateSizeMB: Int {
            switch self {
            case .punctuation:       return 72
            }
        }
    }

    // MARK: - Selected Model (persisted)

    private static let selectedModelKey = "tf_selectedStreamingModel"

    /// Raw values of removed models — migrate to senseVoiceSmall.
    private static let removedModelRawValues: Set<String> = [
        "zipformer-small-ctc", "zipformer-ctc-multi", "paraformer-bilingual"
    ]

    nonisolated static var selectedStreamingModel: StreamingModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectedModelKey) {
                if let model = StreamingModel(rawValue: raw) {
                    return model
                }
                // Migrate removed models
                if removedModelRawValues.contains(raw) {
                    UserDefaults.standard.set(StreamingModel.senseVoiceSmall.rawValue, forKey: selectedModelKey)
                    return .senseVoiceSmall
                }
            }
            return .senseVoiceSmall
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelKey)
        }
    }

    // MARK: - Model Status

    enum ModelStatus: Sendable, Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case invalid
    }

    /// Current download progress keyed by directory name.
    private var downloadProgress: [String: Double] = [:]

    /// Active download tasks keyed by directory name.
    private var activeTasks: [String: Task<Void, Error>] = [:]

    /// Active URLSessions keyed by directory name (for real cancellation).
    private var activeSessions: [String: URLSession] = [:]

    /// Resume data from failed downloads, keyed by directory name.
    private var resumeData: [String: Data] = [:]

    /// Max auto-retry attempts for large downloads.
    private let maxRetries = 20

    // MARK: - Query (Streaming Models)

    // 与 isSelectedModelAvailable 对齐：认用户下载的本地 ASR 模型。
    // （StreamingModel 是旧 sherpa-onnx 路径，现本地识别走 server，这套仅留作状态展示）
    nonisolated func isModelAvailable(_ model: StreamingModel) -> Bool {
        Self.isLocalASRModelAvailable
    }

    /// 本地 ASR 是否有可用模型：server 基础设施已打包，或用户已下载任一 ASR 模型
    /// （SenseVoice / Qwen3-ASR）。修复「下载了模型、测试连接也通，真正调用却报未下载」
    /// ——此前只看 isSenseVoiceBundled（server 二进制是否打包），不认用户下载的模型。
    nonisolated static var isLocalASRModelAvailable: Bool {
        isSenseVoiceBundled
            || isSenseVoiceModelDownloaded
            || SenseVoiceServerManager.resolveQwen3ModelPath() != nil
    }

    nonisolated func isSelectedModelAvailable() -> Bool {
        Self.isLocalASRModelAvailable
    }

    /// Legacy compatibility — used by RecognitionSession.
    nonisolated func areRequiredModelsAvailable() -> Bool {
        isSelectedModelAvailable()
    }

    func status(for model: StreamingModel) -> ModelStatus {
        let key = model.directoryName
        if let progress = downloadProgress[key], progress < 1.0 {
            return .downloading(progress: progress)
        }
        if isModelAvailable(model) { return .downloaded }
        return .notDownloaded
    }

    nonisolated func modelPath(for model: StreamingModel) -> String? {
        guard isModelAvailable(model) else { return nil }
        return (Self.defaultModelsDir as NSString).appendingPathComponent(model.directoryName)
    }

    // MARK: - Query (Auxiliary Models)

    nonisolated func isModelAvailable(_ aux: AuxModelType) -> Bool {
        checkFiles(dir: aux.directoryName, files: aux.requiredFiles)
    }

    nonisolated func modelPath(for aux: AuxModelType) -> String? {
        guard isModelAvailable(aux) else { return nil }
        return (Self.defaultModelsDir as NSString).appendingPathComponent(aux.directoryName)
    }

    // MARK: - Download (Streaming Model)

    func downloadModel(
        _ model: StreamingModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadGeneric(
            key: model.directoryName,
            url: model.downloadURL,
            requiredFiles: model.requiredFiles,
            onProgress: onProgress
        )
    }

    func cancelDownload(_ model: StreamingModel) {
        cancelGeneric(key: model.directoryName)
    }

    func deleteModel(_ model: StreamingModel) throws {
        try deleteGeneric(key: model.directoryName)
    }

    // MARK: - Download (Auxiliary)

    func downloadModel(
        _ aux: AuxModelType,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await downloadGeneric(
            key: aux.directoryName,
            url: aux.downloadURL,
            requiredFiles: aux.requiredFiles,
            isSingleFile: aux.isSingleFile,
            onProgress: onProgress
        )
    }

    func cancelDownload(_ aux: AuxModelType) {
        cancelGeneric(key: aux.directoryName)
    }

    func deleteModel(_ aux: AuxModelType) throws {
        try deleteGeneric(key: aux.directoryName)
    }

    // MARK: - Local Big Models (Python server / 本地 LLM 引擎用，落地大写 Models/)

    /// 用户下载的大模型根目录，与 bundle 的 Contents/Resources/Models 一一对应。
    /// SenseVoiceServerManager / LocalQwenLLMConfig 的「用户下载」查找位置即此处。
    static var userModelsDir: String {
        AppPaths.support("Models", isDirectory: true).path
    }

    /// 下载 Qwen3.5-9B 本地 LLM（单个 gguf 文件，约 5.6GB）。
    /// 落地为 Models/qwen3.5-9b-q4_k_m.gguf，与 LocalQwenLLMConfig 的 bundleFile 同名以便被发现。
    /// 源走 hf-mirror.com 镜像（国内直连 HuggingFace 常被墙）。
    func downloadQwen3LLM(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: "https://hf-mirror.com/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf") else {
            throw ModelError.downloadFailed(URL(fileURLWithPath: "/"))
        }
        try await downloadSingleFileTo(
            url: url,
            destDir: Self.userModelsDir,
            fileName: "qwen3.5-9b-q4_k_m.gguf",
            key: "qwen3.5-9b",
            onProgress: onProgress
        )
    }

    func cancelQwen3LLMDownload() {
        cancelGeneric(key: "qwen3.5-9b")
    }

    /// 通用单文件下载到指定目录（直接落到 destDir/fileName，不建 key 子目录）。
    /// 复用 downloadWithProgress 的重试 + 断点续传内核。
    private func downloadSingleFileTo(
        url: URL,
        destDir: String,
        fileName: String,
        key: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        cancelGeneric(key: key, clearResumeData: false)
        downloadProgress[key] = 0
        onProgress(0)
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let task = Task {
            let tempFile = try await downloadWithProgress(
                url: url,
                key: key,
                onProgress: { [weak self] progress in
                    Task { await self?.setProgress(key, progress) }
                    onProgress(progress)
                }
            )
            try Task.checkCancellation()
            onProgress(0.97)

            let destPath = (destDir as NSString).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(atPath: destPath)
            }
            try FileManager.default.moveItem(at: tempFile, to: URL(fileURLWithPath: destPath))

            guard FileManager.default.fileExists(atPath: destPath) else {
                throw ModelError.extractionFailed
            }
            setProgress(key, 1.0)
            onProgress(1.0)
            logger.info("Big model file ready at \(destPath)")
        }

        activeTasks[key] = task
        try await task.value
        activeTasks[key] = nil
        activeSessions[key] = nil
    }

    // 多文件本地模型（一个 repo 多个文件下到 Models/<subdir>/，供 Python server 加载）
    struct MultiFileModelSpec: Sendable {
        let key: String
        let subdir: String
        let repoBase: String        // hf-mirror resolve/main 基址
        let files: [String]
        let requiredFiles: [String] // 校验：这些在即视为成功
    }

    static let senseVoiceMultiFile = MultiFileModelSpec(
        key: "sensevoice",
        subdir: "SenseVoiceSmall",
        repoBase: "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/main/",
        files: ["model.pt", "config.yaml", "am.mvn", "chn_jpn_yue_eng_ko_spectok.bpe.model", "configuration.json"],
        requiredFiles: ["model.pt", "config.yaml"]
    )

    static let qwen3ASRMultiFile = MultiFileModelSpec(
        key: "qwen3-asr",
        subdir: "Qwen3-ASR",
        repoBase: "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/main/",
        files: ["config.json", "model.safetensors", "model.safetensors.index.json", "generation_config.json", "merges.txt", "preprocessor_config.json", "tokenizer_config.json", "vocab.json", "chat_template.json"],
        requiredFiles: ["config.json", "model.safetensors"]
    )

    /// SenseVoice 模型是否已下载到用户目录（区别于看 server 二进制的 isSenseVoiceBundled）
    nonisolated static var isSenseVoiceModelDownloaded: Bool {
        let p = (userModelsDir as NSString).appendingPathComponent("SenseVoiceSmall/model.pt")
        return FileManager.default.fileExists(atPath: p)
    }

    /// 多文件下载：逐个文件下到 Models/<subdir>/，进度按文件数均摊
    func downloadMultiFileModel(
        _ spec: MultiFileModelSpec,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        cancelGeneric(key: spec.key, clearResumeData: false)
        let destDir = (Self.userModelsDir as NSString).appendingPathComponent(spec.subdir)
        downloadProgress[spec.key] = 0
        onProgress(0)
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let task = Task {
            let total = spec.files.count
            for (i, file) in spec.files.enumerated() {
                try Task.checkCancellation()
                guard let url = URL(string: spec.repoBase + file) else {
                    throw ModelError.downloadFailed(URL(fileURLWithPath: file))
                }
                let tempFile = try await downloadWithProgress(
                    url: url,
                    key: spec.key,
                    onProgress: { frac in
                        let overall = (Double(i) + min(frac, 1.0)) / Double(total)
                        Task { await self.setProgress(spec.key, overall) }
                        onProgress(overall)
                    }
                )
                let destPath = (destDir as NSString).appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(atPath: destPath)
                }
                try FileManager.default.moveItem(at: tempFile, to: URL(fileURLWithPath: destPath))
            }
            let ok = spec.requiredFiles.allSatisfy {
                FileManager.default.fileExists(atPath: (destDir as NSString).appendingPathComponent($0))
            }
            guard ok else {
                try? FileManager.default.removeItem(atPath: destDir)
                throw ModelError.extractionFailed
            }
            setProgress(spec.key, 1.0)
            onProgress(1.0)
            logger.info("Multi-file model \(spec.subdir) ready at \(destDir)")
        }

        activeTasks[spec.key] = task
        try await task.value
        activeTasks[spec.key] = nil
        activeSessions[spec.key] = nil
    }

    func cancelMultiFileDownload(_ spec: MultiFileModelSpec) {
        cancelGeneric(key: spec.key)
    }

    /// 删除已下载的本地模型（按 UI 清单 id），删后回到「未下载」、可重新下载
    func deleteLocalModel(id: String) throws {
        let fm = FileManager.default
        let big = Self.userModelsDir as NSString
        switch id {
        case "qwen3.5-9b":
            let p = big.appendingPathComponent("qwen3.5-9b-q4_k_m.gguf")
            if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
        case "sensevoice":
            let p = big.appendingPathComponent("SenseVoiceSmall")
            if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
        case "qwen3-asr":
            let p = big.appendingPathComponent("Qwen3-ASR")
            if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
        case "punctuation":
            try deleteModel(AuxModelType.punctuation)
        default:
            break
        }
    }

    // MARK: - Generic Download

    private func downloadGeneric(
        key: String,
        url: URL,
        requiredFiles: [String],
        isSingleFile: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Cancel any existing download task but keep resume data for continuation
        cancelGeneric(key: key, clearResumeData: false)

        let destDir = (modelsDir as NSString).appendingPathComponent(key)
        logger.info("Starting download: \(key) from \(url.absoluteString)")
        downloadProgress[key] = 0
        onProgress(0)

        try FileManager.default.createDirectory(
            atPath: modelsDir,
            withIntermediateDirectories: true
        )

        let task = Task {
            let tempFile = try await downloadWithProgress(
                url: url,
                key: key,
                onProgress: { [weak self] progress in
                    Task { await self?.setProgress(key, progress) }
                    onProgress(progress)
                }
            )

            try Task.checkCancellation()

            onProgress(0.95)

            if isSingleFile {
                // Single file download: create directory and move file directly
                logger.info("Placing single file \(key) into \(destDir)")
                try FileManager.default.createDirectory(
                    atPath: destDir,
                    withIntermediateDirectories: true
                )
                let fileName = requiredFiles.first ?? url.lastPathComponent
                let destPath = (destDir as NSString).appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(atPath: destPath)
                }
                try FileManager.default.moveItem(
                    at: tempFile,
                    to: URL(fileURLWithPath: destPath)
                )
            } else {
                // Archive download: extract tar.bz2
                logger.info("Extracting \(key) to \(self.modelsDir)")
                do {
                    try await extractTarBz2(tempFile, to: modelsDir)
                } catch {
                    let partialDir = (modelsDir as NSString).appendingPathComponent(key)
                    try? FileManager.default.removeItem(atPath: partialDir)
                    try? FileManager.default.removeItem(at: tempFile)
                    throw error
                }
                try? FileManager.default.removeItem(at: tempFile)
            }

            guard checkFiles(dir: key, files: requiredFiles) else {
                logger.error("Model validation failed: \(key)")
                try? FileManager.default.removeItem(atPath: destDir)
                throw ModelError.extractionFailed
            }

            setProgress(key, 1.0)
            onProgress(1.0)
            logger.info("Model \(key) ready at \(destDir)")
        }

        activeTasks[key] = task
        try await task.value
        activeTasks[key] = nil
        activeSessions[key] = nil
    }

    private func cancelGeneric(key: String, clearResumeData: Bool = true) {
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        activeSessions[key]?.invalidateAndCancel()
        activeSessions[key] = nil
        downloadProgress[key] = nil
        if clearResumeData {
            resumeData[key] = nil
        }
    }

    private func deleteGeneric(key: String) throws {
        let dir = (modelsDir as NSString).appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.removeItem(atPath: dir)
            logger.info("Deleted model: \(key)")
        }
        downloadProgress[key] = nil
    }

    // MARK: - Internal Helpers

    private nonisolated func checkFiles(dir: String, files: [String]) -> Bool {
        let fullDir = (Self.defaultModelsDir as NSString).appendingPathComponent(dir)
        let fm = FileManager.default
        return files.allSatisfy { file in
            fm.fileExists(atPath: (fullDir as NSString).appendingPathComponent(file))
        }
    }

    private func setProgress(_ key: String, _ value: Double) {
        downloadProgress[key] = value
    }

    private func downloadWithProgress(
        url: URL,
        key: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                try Task.checkCancellation()

                if attempt > 0 {
                    // Exponential backoff: 3, 5, 8, 10, 10, ...
                    let delay = min(3.0 + 2.0 * Double(attempt - 1), 10.0)
                    logger.info("Retry \(attempt)/\(self.maxRetries) for \(key) in \(delay)s")
                    try await Task.sleep(for: .seconds(delay))
                    try Task.checkCancellation()
                }

                let existingResumeData = resumeData[key]
                let (tempURL, response) = try await downloadFile(
                    url: url,
                    key: key,
                    existingResumeData: existingResumeData,
                    onProgress: onProgress
                )

                // Success — clear resume data
                resumeData[key] = nil

                guard let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 206) else {
                    throw ModelError.downloadFailed(url)
                }

                return tempURL
            } catch {
                lastError = error

                if Task.isCancelled { throw error }

                // Check for resume data in the error
                let nsError = error as NSError
                if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData[key] = data
                    logger.info("Download interrupted for \(key), got resume data (\(data.count) bytes), will retry")
                    continue
                }

                // Also check underlying error
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                   let data = underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    resumeData[key] = data
                    logger.info("Download interrupted for \(key), got resume data from underlying error, will retry")
                    continue
                }

                // For network errors without resume data, still retry (just from scratch)
                let code = nsError.code
                let retryableCodes: Set<Int> = [
                    NSURLErrorTimedOut,                  // -1001
                    NSURLErrorCannotConnectToHost,       // -1004
                    NSURLErrorNetworkConnectionLost,     // -1005
                    NSURLErrorNotConnectedToInternet,    // -1009
                    NSURLErrorSecureConnectionFailed,    // -1200
                ]
                if nsError.domain == NSURLErrorDomain, retryableCodes.contains(code) {
                    logger.info("Download failed for \(key) (retryable error \(code)), will retry from scratch")
                    continue
                }

                // Non-retryable error — throw immediately
                logger.error("Download failed for \(key) (non-retryable): \(error)")
                throw error
            }
        }

        throw lastError ?? ModelError.downloadFailed(url)
    }

    private func downloadFile(
        url: URL,
        key: String,
        existingResumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let delegate = DownloadProgressDelegate(
                onProgress: { fraction in
                    onProgress(fraction * 0.9)
                },
                onComplete: { location, response, error in
                    let shouldResume = didResume.withLock { alreadyResumed in
                        guard !alreadyResumed else { return false }
                        alreadyResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: ModelError.extractionFailed)
                        return
                    }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".tar.bz2")
                    do {
                        try FileManager.default.moveItem(at: location, to: dest)
                        continuation.resume(returning: (dest, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300       // 5 min per chunk
            config.timeoutIntervalForResource = 7200     // 2 hours total
            config.waitsForConnectivity = true
            config.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            Task { self.storeSession(session, forKey: key) }

            // Resume from previous partial download if available
            if let data = existingResumeData {
                logger.info("Resuming download for \(key) with \(data.count) bytes of resume data")
                session.downloadTask(withResumeData: data).resume()
            } else {
                session.downloadTask(with: URLRequest(url: url)).resume()
            }
        }
    }

    private func storeSession(_ session: URLSession, forKey key: String) {
        activeSessions[key] = session
    }

    private func extractTarBz2(_ archive: URL, to destDir: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", archive.path, "-C", destDir]
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            logger.error("tar extraction failed (status \(process.terminationStatus)): \(errMsg)")
            throw ModelError.extractionFailed
        }
    }

    // MARK: - Errors

    enum ModelError: Error, LocalizedError {
        case downloadFailed(URL)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let url):
                return L("模型下载失败: \(url.lastPathComponent)", "Model download failed: \(url.lastPathComponent)")
            case .extractionFailed:
                return L("模型解压失败", "Model extraction failed")
            }
        }
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void

    /// Retain the completed file URL until the task delegate fires.
    private var completedURL: URL?
    private var completedResponse: URLResponse?

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to temp before system cleans up the delegate-provided location
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".partial")
        try? FileManager.default.copyItem(at: location, to: temp)
        completedURL = temp
        completedResponse = downloadTask.response
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(completedURL, completedResponse, nil)
        }
        session.invalidateAndCancel()
    }
}
