import AppKit
import XCTest
@testable import Muse

final class SettingsWindowPresenterTests: XCTestCase {
    @MainActor
    func testReusesSwiftUISettingsWindowBeforeCreatingManualWindow() async {
        _ = NSApplication.shared
        let window = makeWindow(identifier: "settings")
        XCTAssertTrue(SettingsWindowPresenter.existingSettingsWindow(in: [window], retained: nil) === window)
    }

    @MainActor
    func testClosedRetainedWindowCanBeReopenedWithoutCreatingAnother() async {
        _ = NSApplication.shared
        let window = makeWindow(identifier: "settings")
        XCTAssertTrue(SettingsWindowPresenter.existingSettingsWindow(in: [], retained: window) === window)
    }

    @MainActor
    func testIgnoresSetupAndOtherWindowsWithTheSameTitle() async {
        _ = NSApplication.shared
        let setup = makeWindow(identifier: "setup")
        setup.title = "Muse 设置"
        XCTAssertNil(SettingsWindowPresenter.existingSettingsWindow(in: [setup], retained: nil))
        let settings = makeWindow(identifier: "settings")
        XCTAssertTrue(SettingsWindowPresenter.existingSettingsWindow(in: [setup, settings], retained: nil) === settings)
    }

    @MainActor
    private func makeWindow(identifier: String) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }
}
