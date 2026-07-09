import AppKit
@testable import Muse
import XCTest

final class TextInjectionEngineIntegrationTests: XCTestCase {
    @MainActor
    func testClipboardInjectionIntoTextEdit() throws {
        guard ProcessInfo.processInfo.environment["MUSE_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set MUSE_RUN_UI_INJECTION_TEST=1 to run the TextEdit injection test.")
        }

        try ensureTextEditIsRunning()
        let marker = "MUSE_ENGINE_INJECTION_TEST_\(UUID().uuidString)"
        try prepareTextEditDocument()
        defer {
            _ = try? closeFrontTextEditDocument()
        }

        try activateTextEdit()

        // REPAIR_PLAN J16：AX 直插零剪贴板占用——注入全程剪贴板保持原内容
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("剪贴板原有内容", forType: .string)

        let engine = TextInjectionEngine()
        engine.preserveClipboard = false

        XCTAssertEqual(engine.inject(marker), .inserted)

        let documentText = try waitForFrontTextEditDocument(containing: marker)
        XCTAssertTrue(
            documentText.contains(marker),
            "Expected TextEdit document to contain injected marker, got: \(documentText)"
        )

        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(
            clipboardText,
            "剪贴板原有内容",
            "AX direct insertion must not touch the clipboard at all (REPAIR_PLAN J16)."
        )
    }

    @MainActor
    func testClipboardInjectionLeavesCaretAfterInsertedTextInTextEdit() throws {
        guard ProcessInfo.processInfo.environment["MUSE_RUN_UI_INJECTION_TEST"] == "1" else {
            throw XCTSkip("Set MUSE_RUN_UI_INJECTION_TEST=1 to run the TextEdit injection test.")
        }

        try ensureTextEditIsRunning()
        let prefix = "prefix-"
        let marker = "museinjection\(Int(Date().timeIntervalSince1970))"
        let suffix = "-suffix"
        try prepareTextEditDocument()
        defer {
            _ = try? closeFrontTextEditDocument()
        }

        try activateTextEdit()
        try runAppleScript("""
        tell application "System Events"
            keystroke "\(prefix)"
        end tell
        """)
        _ = try waitForFrontTextEditDocument(containing: prefix)

        let engine = TextInjectionEngine()
        engine.preserveClipboard = false

        XCTAssertEqual(engine.inject(marker), .inserted)
        _ = try waitForFrontTextEditDocument(containing: prefix + marker)
        try runAppleScript("""
        tell application "System Events"
            keystroke "\(suffix)"
        end tell
        """)

        let documentText = try waitForFrontTextEditDocument(containing: prefix + marker + suffix)
        XCTAssertTrue(
            documentText.contains(prefix + marker + suffix),
            "Expected caret to remain after injected text. Got: \(documentText)"
        )
    }

    private func waitForRunningApplication(
        bundleIdentifier: String,
        timeout: TimeInterval = 3
    ) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let application = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) {
                return application
            }
            usleep(50_000)
        }
        return nil
    }

    private func ensureTextEditIsRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.apple.TextEdit"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to launch TextEdit via open."]
            )
        }
        guard waitForRunningApplication(bundleIdentifier: "com.apple.TextEdit") != nil else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TextEdit did not become available after open."]
            )
        }
    }

    private func prepareTextEditDocument() throws {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            activate
            make new document with properties {text:""}
        end tell
        """)
    }

    private func closeFrontTextEditDocument() throws {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            if exists document 1 then close front document saving no
        end tell
        """)
    }

    private func readFrontTextEditDocument() throws -> String {
        try runAppleScript("""
        tell application id "com.apple.TextEdit"
            if exists document 1 then return text of front document
            return ""
        end tell
        """)
    }

    private func waitForFrontTextEditDocument(
        containing expectedText: String,
        timeout: TimeInterval = 3
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latestText = ""
        while Date() < deadline {
            latestText = try readFrontTextEditDocument()
            if latestText.contains(expectedText) {
                return latestText
            }
            usleep(100_000)
        }
        return latestText
    }

    private func activateTextEdit(timeout: TimeInterval = 3) throws {
        guard let textEdit = waitForRunningApplication(bundleIdentifier: "com.apple.TextEdit") else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TextEdit did not launch."]
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = textEdit.activate(options: [.activateAllWindows])
            usleep(100_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" {
                return
            }
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        throw NSError(
            domain: "TextInjectionEngineIntegrationTests",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "TextEdit did not become frontmost. Current frontmost app: \(frontmost)."
            ]
        )
    }

    @discardableResult
    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TextInjectionEngineIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput]
            )
        }

        return output
    }
}
