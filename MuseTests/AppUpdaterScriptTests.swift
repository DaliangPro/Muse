import Foundation
import XCTest
@testable import Muse

/// REPAIR_PLAN J17：更新脚本含替换 App bundle 的破坏性操作，必须有脚本级路径闸门。
final class AppUpdaterScriptTests: XCTestCase {

    func testUpdaterScriptPassesBashSyntaxCheck() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.trashItem(at: fixture.root, resultingItemURL: nil) }

        let result = try runBash(arguments: ["-n", fixture.scriptURL.path])

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testUpdaterScriptDryRunAcceptsSafeEnvironment() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.trashItem(at: fixture.root, resultingItemURL: nil) }

        let result = try runUpdaterScript(
            scriptURL: fixture.scriptURL,
            appPath: fixture.appURL.path,
            dmgPath: fixture.dmgURL.path,
            stagingDir: fixture.stagingURL.path
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("DRY_RUN: updater environment validated"), result.output)
    }

    func testUpdaterScriptRejectsDangerousAppPathBeforeDryRun() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.trashItem(at: fixture.root, resultingItemURL: nil) }

        let result = try runUpdaterScript(
            scriptURL: fixture.scriptURL,
            appPath: "/",
            dmgPath: fixture.dmgURL.path,
            stagingDir: fixture.stagingURL.path
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("APP_PATH points at an unsafe root"), result.output)
    }

    private struct Fixture {
        let root: URL
        let stagingURL: URL
        let appURL: URL
        let dmgURL: URL
        let scriptURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("muse-updater-script-\(UUID().uuidString)")
        let stagingURL = root.appendingPathComponent("Updates", isDirectory: true)
        let appURL = root.appendingPathComponent("Muse.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let dmgURL = stagingURL.appendingPathComponent("Muse-v9.9.9-cloud.dmg")
        let scriptURL = stagingURL.appendingPathComponent("updater.sh")

        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try Data().write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data().write(to: dmgURL)
        try AppUpdater.updaterScriptForTesting.write(to: scriptURL, atomically: true, encoding: .utf8)

        return Fixture(root: root, stagingURL: stagingURL, appURL: appURL, dmgURL: dmgURL, scriptURL: scriptURL)
    }

    private func runUpdaterScript(
        scriptURL: URL,
        appPath: String,
        dmgPath: String,
        stagingDir: String
    ) throws -> (status: Int32, output: String) {
        let result = try runBash(
            arguments: [scriptURL.path],
            environment: [
                "APP_PID": "999999",
                "APP_PATH": appPath,
                "DMG_PATH": dmgPath,
                "IS_LOCAL": "0",
                "MUSE_UPDATER_DRY_RUN": "1",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SIGNING_IDENTITY": "-",
                "STAGING_DIR": stagingDir,
            ]
        )
        let logURL = URL(fileURLWithPath: stagingDir).appendingPathComponent("update.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return (result.status, result.output + log)
    }

    private func runBash(
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
