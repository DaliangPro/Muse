import Foundation
import XCTest
@testable import Muse

final class InteractiveTestRuntimeTests: XCTestCase {
    private let candidate = URL(fileURLWithPath: "/Users/test/muse/build/interactive/Muse.app")

    func testProductionBundleIgnoresTestEnvironment() throws {
        XCTAssertNil(try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: "pro.daliang.muse", bundleURL: candidate,
            environment: [InteractiveTestRuntime.rootEnvironmentKey: "/unexpected"]
        ))
    }

    func testTestBundleRequiresExplicitAdjacentDirectory() throws {
        let expected = candidate.deletingLastPathComponent().appendingPathComponent("test-data")
        XCTAssertEqual(try resolve(expected.path)?.path, expected.path)
        for invalid in [nil, "", "test-data", "/Users/test/Library/Application Support/Muse",
                        candidate.appendingPathComponent("test-data").path,
                        candidate.deletingLastPathComponent().appendingPathComponent("another-data").path] {
            XCTAssertThrowsError(try resolve(invalid), "必须拒绝 \(invalid ?? "未配置")")
        }
    }

    func testSymlinkAncestorCannotRedirectTestData() throws {
        let alias = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) != nil else {
            throw XCTSkip("当前系统没有 /tmp 符号链接")
        }
        XCTAssertThrowsError(try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: InteractiveTestRuntime.bundleIdentifier,
            bundleURL: alias.appendingPathComponent("Muse.app"),
            environment: [InteractiveTestRuntime.rootEnvironmentKey: alias.appendingPathComponent("test-data").path]
        ))
    }

    func testTestPreferencesStayVolatileAndDisableLearning() throws {
        let suite = "MuseTests.InteractiveRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(InteractiveTestRuntime.preferences, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.selectedASRProvider), "volcano")
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.selectedLLMProvider), "deepseek")
        XCTAssertEqual(VoicePolishSettings.modelOverride(defaults: defaults), "deepseek-flash")
        XCTAssertEqual(VoicePolishSettings.contextLevel(defaults: defaults), .metadataOnly)
        XCTAssertFalse(VoicePolishSettings.personalizationEnabled(defaults: defaults))
        XCTAssertFalse(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertFalse(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
    }

    private func resolve(_ path: String?) throws -> URL? {
        try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: InteractiveTestRuntime.bundleIdentifier,
            bundleURL: candidate,
            environment: path.map { [InteractiveTestRuntime.rootEnvironmentKey: $0] } ?? [:]
        )
    }
}
