import AppKit
import CommonCrypto
import os

// MARK: - App Updater

@Observable @MainActor
final class AppUpdater {

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case verifying
        case readyToInstall
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var downloadedVersion: String?

    /// Detected once at init
    let isLocalInstallation: Bool

    private let logger = Logger(subsystem: "pro.daliang.muse", category: "AppUpdater")
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var currentRelease: UpdateInfo?

    // MARK: - Directories

    private var stagingDir: URL {
        AppPaths.support("Updates", isDirectory: true)
    }

    private var updateLogURL: URL { stagingDir.appendingPathComponent("update.log") }

    // MARK: - Init

    init() {
        let macosURL = Bundle.main.executableURL?.deletingLastPathComponent()
        isLocalInstallation = FileManager.default.fileExists(
            atPath: macosURL?.appendingPathComponent("sensevoice-server-dist").path ?? ""
        )
    }

    // MARK: - Public API

    func downloadUpdate(release: UpdateInfo) {
        switch state {
        case .idle, .failed: break
        default: return
        }

        currentRelease = release
        downloadedVersion = release.version
        let url = release.resolvedDmgURL

        // Ensure staging directory
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        startDownload(url: url, release: release)
    }

    func cancelDownload() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                self?.resumeData = data
            }
        })
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadTask = nil
        state = .idle
    }

    func retryDownload() {
        guard let release = currentRelease else { return }
        state = .idle
        if resumeData != nil {
            startDownload(url: release.resolvedDmgURL, release: release)
        } else {
            downloadUpdate(release: release)
        }
    }

    func installAndRestart() {
        guard case .readyToInstall = state else { return }
        guard let version = downloadedVersion else { return }

        state = .installing
        let dmgPath = dmgPath(for: version)

        guard FileManager.default.fileExists(atPath: dmgPath.path) else {
            state = .failed(L("下载文件不存在", "Downloaded file not found"))
            return
        }

        let signingIdentity = currentSigningIdentity() ?? "-"
        let scriptURL = stagingDir.appendingPathComponent("updater.sh")

        do {
            try Self.updaterScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            state = .failed(L("无法生成更新脚本: \(error.localizedDescription)",
                              "Failed to generate update script: \(error.localizedDescription)"))
            return
        }

        // Kill ASR servers before quitting
        SenseVoiceServerManager.killAllServerProcesses()

        // Launch updater script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = [
            "APP_PID": "\(ProcessInfo.processInfo.processIdentifier)",
            "APP_PATH": Bundle.main.bundlePath,
            "DMG_PATH": dmgPath.path,
            "SIGNING_IDENTITY": signingIdentity,
            "IS_LOCAL": isLocalInstallation ? "1" : "0",
            "STAGING_DIR": stagingDir.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.qualityOfService = .utility

        do {
            try process.run()
            logger.info("Updater script launched, PID=\(process.processIdentifier)")
        } catch {
            state = .failed(L("无法启动更新脚本: \(error.localizedDescription)",
                              "Failed to launch update script: \(error.localizedDescription)"))
            return
        }

        // Quit the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Check post-update status on launch (called from AppDelegate).
    func checkPostUpdateStatus() {
        guard FileManager.default.fileExists(atPath: updateLogURL.path) else { return }
        defer { cleanupStaging() }

        guard let log = try? String(contentsOf: updateLogURL, encoding: .utf8) else { return }
        if log.contains("SUCCESS") {
            logger.info("Post-update check: update succeeded")
        } else if log.contains("FAILED") {
            logger.error("Post-update check: update failed, see log")
        }
    }

    func reset() {
        state = .idle
        downloadedVersion = nil
        currentRelease = nil
        resumeData = nil
    }

    // MARK: - Download

    private func dmgPath(for version: String) -> URL {
        stagingDir.appendingPathComponent("Muse-v\(version)-cloud.dmg")
    }

    private func startDownload(url: URL, release: UpdateInfo) {
        state = .downloading(progress: 0)

        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: fraction)
                }
            },
            onComplete: { [weak self] fileURL, _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // REPAIR_PLAN J9：下载生命周期终点统一回收会话——URLSession 强持
                    // delegate 直到 invalidate，此前成功路径从不回收，每次下载泄漏一对
                    // session+delegate（用户主动取消由 cancelDownload 的 invalidateAndCancel 负责，
                    // 届时 downloadSession 已为 nil，这里的空调用无害）。
                    self.downloadSession?.finishTasksAndInvalidate()
                    self.downloadSession = nil
                    self.downloadTask = nil
                    if let error {
                        self.handleDownloadError(error)
                        return
                    }
                    guard let fileURL else {
                        self.state = .failed(L("下载失败", "Download failed"))
                        return
                    }
                    self.finalizeDownload(tempURL: fileURL, release: release)
                }
            }
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.downloadSession = session

        if let resumeData {
            self.resumeData = nil
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        downloadTask?.resume()
    }

    private func handleDownloadError(_ error: Error) {
        let nsError = error as NSError
        // Capture resume data for retry
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        // Also check underlying error
        if resumeData == nil,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let data = underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }

        if nsError.code == NSURLErrorCancelled { return } // User cancelled
        let hasResume = resumeData != nil
        let msg = hasResume
            ? L("下载中断，可以继续", "Download interrupted, can resume")
            : L("下载失败: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)")
        state = .failed(msg)
    }

    private func finalizeDownload(tempURL: URL, release: UpdateInfo) {
        let destination = dmgPath(for: release.version)

        // Move downloaded file to staging
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            state = .failed(L("无法保存下载文件: \(error.localizedDescription)",
                              "Failed to save download: \(error.localizedDescription)"))
            return
        }

        // SHA256 verification（REPAIR_PLAN A2：缺校验值一律拒绝安装，不允许静默跳过）
        state = .verifying
        guard Self.isChecksumAcceptable(
            expected: release.cloudDmgSHA256,
            actual: sha256(fileAt: destination)
        ) else {
            try? FileManager.default.removeItem(at: destination)
            let reason = (release.cloudDmgSHA256?.isEmpty ?? true)
                ? L("更新包缺少校验信息，已拒绝安装", "Update is missing its checksum; installation refused")
                : L("文件校验失败，请重新下载", "File verification failed, please retry")
            state = .failed(reason)
            return
        }

        resumeData = nil
        state = .readyToInstall
    }

    /// 校验闸门：期望值缺失、实际值缺失或不匹配，一律不通过（REPAIR_PLAN A2）
    nonisolated static func isChecksumAcceptable(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty,
              let actual, !actual.isEmpty else { return false }
        return expected.lowercased() == actual.lowercased()
    }

    // MARK: - Signing Identity

    private func currentSigningIdentity() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dvvv", Bundle.main.bundlePath]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Authority=") {
                return String(line.dropFirst("Authority=".count))
            }
        }
        return nil
    }

    // MARK: - SHA256

    private func sha256(fileAt url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(read))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Updater Script

    /// 纯常量脚本：全部参数经环境变量传入（J15 收口——原先 stagingDir 以字符串
    /// 插值写进脚本文本，路径含引号/特殊字符时会破坏脚本语法）
    private nonisolated static let updaterScript = """
        #!/bin/bash
        set -euo pipefail

        die() {
            echo "ERROR: $*" >&2
            exit 1
        }

        require_env() {
            local name="$1"
            local value="${!name:-}"
            [ -n "$value" ] || die "$name is required"
        }

        require_absolute_path() {
            local name="$1"
            local value="$2"
            case "$value" in
                /*) ;;
                *) die "$name must be an absolute path: $value" ;;
            esac
        }

        reject_dangerous_root() {
            local name="$1"
            local value="$2"
            case "$value" in
                "/"|"/Applications"|"/Users"|"${HOME:-__muse_no_home__}"|"/tmp"|"/private/tmp")
                    die "$name points at an unsafe root: $value"
                    ;;
            esac
        }

        require_env APP_PID
        require_env APP_PATH
        require_env DMG_PATH
        require_env IS_LOCAL
        require_env SIGNING_IDENTITY
        require_env STAGING_DIR

        require_absolute_path STAGING_DIR "$STAGING_DIR"
        reject_dangerous_root STAGING_DIR "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"

        LOG="$STAGING_DIR/update.log"
        exec > "$LOG" 2>&1
        echo "Muse updater started at $(date)"

        require_absolute_path APP_PATH "$APP_PATH"
        require_absolute_path DMG_PATH "$DMG_PATH"
        reject_dangerous_root APP_PATH "$APP_PATH"
        reject_dangerous_root DMG_PATH "$DMG_PATH"
        case "$APP_PID" in
            ''|*[!0-9]*) die "APP_PID must be numeric: $APP_PID" ;;
        esac
        case "$APP_PATH" in
            *.app) ;;
            *) die "APP_PATH must point to an .app bundle: $APP_PATH" ;;
        esac
        [ -d "$APP_PATH/Contents" ] || die "APP_PATH is not an app bundle: $APP_PATH"
        case "$DMG_PATH" in
            "$STAGING_DIR"/*.dmg) ;;
            *) die "DMG_PATH must be a .dmg inside STAGING_DIR: $DMG_PATH" ;;
        esac
        case "$IS_LOCAL" in
            0|1) ;;
            *) die "IS_LOCAL must be 0 or 1: $IS_LOCAL" ;;
        esac

        BACKUP_PATH="$STAGING_DIR/Muse-backup.app"

        safe_rm_rf() {
            local target="$1"
            [ -n "$target" ] || die "refusing rm -rf on empty path"
            require_absolute_path "rm target" "$target"
            reject_dangerous_root "rm target" "$target"
            case "$target" in
                "$APP_PATH"|"$BACKUP_PATH"|"${TEMP_LOCAL:-__muse_no_temp__}"|"${SERVER_TEMP:-__muse_no_server_temp__}"|"$STAGING_DIR"/*)
                    rm -rf "$target"
                    ;;
                *)
                    die "refusing rm -rf outside updater-owned paths: $target"
                    ;;
            esac
        }

        safe_rm_file() {
            local target="$1"
            [ -n "$target" ] || die "refusing rm -f on empty path"
            require_absolute_path "rm file target" "$target"
            case "$target" in
                "$STAGING_DIR"/*.dmg)
                    rm -f "$target"
                    ;;
                *)
                    die "refusing rm -f outside updater-owned files: $target"
                    ;;
            esac
        }

        if [ "${MUSE_UPDATER_DRY_RUN:-0}" = "1" ]; then
            echo "DRY_RUN: updater environment validated"
            exit 0
        fi

        # Wait for app to exit
        while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        echo "App exited."

        # Mount DMG
        echo "Mounting DMG..."
        MOUNT_OUTPUT=$(hdiutil attach -nobrowse -noverify -mountrandom /tmp "$DMG_PATH" 2>&1)
        MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk '/\\/tmp\\// {print $NF; exit}')
        [ -n "$MOUNT_POINT" ] || die "failed to resolve DMG mount point"
        echo "Mounted at $MOUNT_POINT"

        cleanup_mount() {
            [ -n "${MOUNT_POINT:-}" ] && hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
        }
        trap cleanup_mount EXIT

        # Find .app in DMG
        NEW_APP=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)
        if [ -z "$NEW_APP" ] || [ ! -d "$NEW_APP" ]; then
            echo "ERROR: Muse.app not found in DMG"
            exit 1
        fi
        echo "Found: $NEW_APP"

        CURRENT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
        NEW_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$NEW_APP/Contents/Info.plist")
        if [ "$CURRENT_BUNDLE_ID" != "$NEW_BUNDLE_ID" ]; then
            echo "ERROR: bundle id mismatch: current=$CURRENT_BUNDLE_ID new=$NEW_BUNDLE_ID"
            exit 1
        fi

        echo "Verifying new app signature..."
        codesign --verify --deep --strict "$NEW_APP"

        CURRENT_TEAM=$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2; exit}')
        NEW_TEAM=$(codesign -dvvv "$NEW_APP" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2; exit}')
        # REPAIR_PLAN J7：当前安装无 TeamIdentifier（ad-hoc/自签）时更新链没有身份锚点，
        # 任何能过 codesign --verify 的自签 DMG 都会被接受——此前这里整体跳过比对即静默放行。
        # 改为直接拒绝自动更新：ad-hoc 安装的用户须手动安装带真实开发者签名的版本后，
        # 自动更新方可恢复（A1 重开更新通道的前置条件之一）。
        if [ -z "$CURRENT_TEAM" ] || [ "$CURRENT_TEAM" = "not set" ]; then
            echo "ERROR: current install has no TeamIdentifier (ad-hoc/self-signed); auto-update refused"
            exit 1
        fi
        if [ "$CURRENT_TEAM" != "$NEW_TEAM" ]; then
            echo "ERROR: signing team mismatch: current=$CURRENT_TEAM new=$NEW_TEAM"
            exit 1
        fi
        echo "New app passed identity checks."

        # Backup current app
        safe_rm_rf "$BACKUP_PATH"
        echo "Backing up $APP_PATH..."
        cp -R "$APP_PATH" "$BACKUP_PATH"

        # Rollback on error
        rollback() {
            set +e
            echo "ERROR: Update failed, rolling back..."
            if [ -d "$BACKUP_PATH" ]; then
                safe_rm_rf "$APP_PATH" 2>/dev/null || true
                mv "$BACKUP_PATH" "$APP_PATH"
                echo "Rolled back to backup."
            fi
            open "$APP_PATH" &
            echo "FAILED"
        }
        trap 'rollback; cleanup_mount' ERR

        # Preserve local components (server dists + models)
        TEMP_LOCAL=""
        if [ "$IS_LOCAL" = "1" ]; then
            TEMP_LOCAL="$(mktemp -d)"
            echo "Preserving local components to $TEMP_LOCAL..."
            for item in sensevoice-server-dist sensevoice-server qwen3-asr-server-dist qwen3-asr-server; do
                [ -e "$APP_PATH/Contents/MacOS/$item" ] && mv "$APP_PATH/Contents/MacOS/$item" "$TEMP_LOCAL/"
            done
            [ -d "$APP_PATH/Contents/Resources/Models" ] && mv "$APP_PATH/Contents/Resources/Models" "$TEMP_LOCAL/"
        fi

        # Replace app
        echo "Replacing app bundle..."
        safe_rm_rf "$APP_PATH"
        cp -R "$NEW_APP" "$APP_PATH"

        # Restore local components
        if [ "$IS_LOCAL" = "1" ] && [ -n "$TEMP_LOCAL" ] && [ -d "$TEMP_LOCAL" ]; then
            echo "Restoring local components..."
            for item in sensevoice-server-dist sensevoice-server qwen3-asr-server-dist qwen3-asr-server; do
                [ -e "$TEMP_LOCAL/$item" ] && mv "$TEMP_LOCAL/$item" "$APP_PATH/Contents/MacOS/"
            done
            [ -d "$TEMP_LOCAL/Models" ] && mv "$TEMP_LOCAL/Models" "$APP_PATH/Contents/Resources/"
            safe_rm_rf "$TEMP_LOCAL"
        fi

        # Code sign only if a real signing identity is available (not ad-hoc).
        # The DMG already contains a properly signed app; re-signing with "-"
        # would strip the original signature and trigger Gatekeeper "damaged" errors.
        if [ "$SIGNING_IDENTITY" != "-" ] && [ -n "$SIGNING_IDENTITY" ]; then
            echo "Signing with identity: $SIGNING_IDENTITY"
            SERVER_TEMP=""
            if [ -d "$APP_PATH/Contents/MacOS/sensevoice-server-dist" ]; then
                SERVER_TEMP="$(mktemp -d)"
                for item in sensevoice-server-dist sensevoice-server qwen3-asr-server-dist qwen3-asr-server; do
                    [ -e "$APP_PATH/Contents/MacOS/$item" ] && mv "$APP_PATH/Contents/MacOS/$item" "$SERVER_TEMP/"
                done
            fi

            codesign -f -s "$SIGNING_IDENTITY" "$APP_PATH"

            if [ -n "$SERVER_TEMP" ] && [ -d "$SERVER_TEMP" ]; then
                for item in sensevoice-server-dist sensevoice-server qwen3-asr-server-dist qwen3-asr-server; do
                    [ -e "$SERVER_TEMP/$item" ] && mv "$SERVER_TEMP/$item" "$APP_PATH/Contents/MacOS/"
                done
                safe_rm_rf "$SERVER_TEMP"
            fi
        else
            echo "Skipping code signing (no developer identity, preserving original signature)"
        fi

        # Remove quarantine
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

        # Cleanup
        echo "Cleaning up..."
        safe_rm_file "$DMG_PATH"
        safe_rm_rf "$BACKUP_PATH"

        # Relaunch
        echo "Relaunching..."
        open "$APP_PATH" &

        echo "Update completed successfully at $(date)"
        echo "SUCCESS"
        """

    nonisolated static var updaterScriptForTesting: String { updaterScript }

    // MARK: - Cleanup

    private func cleanupStaging() {
        try? FileManager.default.removeItem(at: stagingDir)
    }
}

// MARK: - Download Delegate

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void
    private var completedURL: URL?

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
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")
        try? FileManager.default.copyItem(at: location, to: temp)
        completedURL = temp
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(completedURL, task.response, nil)
        }
    }
}
