import AppKit
import XCTest
@testable import Muse

final class SettingsWindowTrafficLightAlignerTests: XCTestCase {
    @MainActor
    func testButtonsRemainInsideNativeTitlebarAfterRepeatedAlignment() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 736, height: 588),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let aligner = SettingsWindowTrafficLightAligner(leadingInset: 16, topInset: 16)
        for _ in 0..<3 {
            aligner.align(in: window)
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                let container = try XCTUnwrap(button.superview)
                XCTAssertTrue(container.bounds.contains(button.frame), "按钮被标题栏裁切：\(button.frame)，容器：\(container.bounds)")
            }
        }
    }
}
