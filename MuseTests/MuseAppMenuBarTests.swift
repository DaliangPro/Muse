import AppKit
import XCTest
@testable import Muse

final class MuseAppMenuBarTests: XCTestCase {
    @MainActor
    func test交互测试面板保持目标焦点并复用菜单动作() throws {
        let panel = AppDelegate.makeInteractiveTestControlPanel(target: nil)
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        let menu = AppDelegate.makeInteractiveTestStatusMenu(target: nil)

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(buttons.map(\.title), menu.items.map(\.title))
        XCTAssertEqual(buttons.map(\.action), menu.items.map(\.action))
        XCTAssertTrue(buttons.allSatisfy { $0.keyEquivalent.isEmpty })
        XCTAssertTrue(content.subviews.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "先点选空白输入框，再开始录音"
        })
    }

    @MainActor
    func test交互测试菜单只暴露手动测试动作并且没有快捷键() {
        let menu = AppDelegate.makeInteractiveTestStatusMenu(target: nil)

        XCTAssertEqual(menu.items.map(\.title), [
            "准备录音与上屏权限", "开始轻度录音", "开始直出录音", "停止并上屏", "退出测试",
        ])
        XCTAssertEqual(menu.items.compactMap { $0.action.map(NSStringFromSelector) }, [
            "prepareInteractiveTestPermissions", "startInteractiveLightRecording",
            "startInteractiveDirectRecording", "stopInteractiveRecording", "quitFromStatusMenu",
        ])
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    func test菜单栏图标保持原尺寸不被AppKit向上放大() {
        XCTAssertEqual(MuseApp.menuBarImageScaling, .scaleProportionallyDown)
    }

    func testMacOS26保留系统状态项身份避免身份分叉() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        XCTAssertNil(MuseApp.statusItemAutosaveName(for: version))
    }

    func test旧版MacOS继续使用稳定状态项名称() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)

        XCTAssertEqual(
            MuseApp.statusItemAutosaveName(for: version),
            MuseApp.menuBarAutosaveName
        )
    }

    func test首次迁移会清除旧状态项隐藏记录() throws {
        let suiteName = "MuseAppMenuBarTests.首次迁移.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for key in MuseApp.legacyMenuBarVisibilityKeys {
            defaults.set(false, forKey: key)
        }

        MuseApp.migrateLegacyMenuBarVisibilityIfNeeded(defaults: defaults)

        for key in MuseApp.legacyMenuBarVisibilityKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
        XCTAssertEqual(
            defaults.double(forKey: MuseApp.menuBarPreferredPositionKey),
            MuseApp.defaultMenuBarPreferredPosition
        )
        XCTAssertTrue(defaults.bool(forKey: MuseApp.menuBarVisibilityMigrationKey))
    }

    func test完成迁移后不再覆盖系统状态项记录() throws {
        let suiteName = "MuseAppMenuBarTests.保留后续状态.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = try XCTUnwrap(MuseApp.legacyMenuBarVisibilityKeys.first)
        defaults.set(true, forKey: MuseApp.menuBarVisibilityMigrationKey)
        defaults.set(false, forKey: legacyKey)
        defaults.set(123.0, forKey: MuseApp.menuBarPreferredPositionKey)

        MuseApp.migrateLegacyMenuBarVisibilityIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: legacyKey) as? Bool, false)
        XCTAssertEqual(defaults.double(forKey: MuseApp.menuBarPreferredPositionKey), 123.0)
    }
}
