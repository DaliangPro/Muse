import XCTest
@testable import Muse

final class MuseAppMenuBarTests: XCTestCase {
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
