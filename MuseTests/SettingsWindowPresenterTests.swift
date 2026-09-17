import AppKit
import XCTest
@testable import Muse

final class SettingsWindowPresenterTests: XCTestCase {
    @MainActor
    func testOpenBeforeSceneActionIsReadyQueuesOnlyOneOpen() async {
        _ = NSApplication.shared
        let presenter = SettingsWindowPresenter()
        var calls = 0
        presenter.open()
        presenter.open()
        XCTAssertEqual(calls, 0)
        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.register { calls += 1 }
        XCTAssertEqual(calls, 1)
        presenter.open()
        XCTAssertEqual(calls, 2)
    }

}
