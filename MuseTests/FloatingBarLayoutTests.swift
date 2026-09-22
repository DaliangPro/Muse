import AppKit
import SwiftUI
import XCTest
@testable import Muse

final class FloatingBarLayoutTests: XCTestCase {
    @MainActor
    func testGlassRespectsOuterSizeWhenIndicatorHasLargerIntrinsicSize() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("原生玻璃需要 macOS 26")
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView:
            CleanGlassCapsule(
                cornerRadius: 20,
                style: .regular,
                tintColor: nil,
                content: AnyView(Color.clear.frame(width: 44, height: 44))
            )
            .frame(width: 40, height: 40)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let glass = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(glass.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(glass.bounds.height, 40, accuracy: 0.5)
        XCTAssertEqual(glass.cornerRadius, min(glass.bounds.width, glass.bounds.height) / 2, accuracy: 0.5)
    }

    @MainActor
    func testRecordingCircleRemainsRoundBeforeAndAfterTextExpansion() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("原生玻璃需要 macOS 26")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousRegistration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["museGlassMinimal": true])
        defer { defaults.setVolatileDomain(previousRegistration, forName: UserDefaults.registrationDomain) }

        let state = DemoState()
        state.barPhase = .recording
        let host = NSHostingView(rootView: FloatingBarView(state: state)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 180)

        try await settleLayout(host)
        let initial = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(initial.bounds.width, 48, accuracy: 0.5)
        XCTAssertEqual(initial.bounds.height, initial.bounds.width, accuracy: 0.5)
        XCTAssertEqual(initial.cornerRadius, initial.bounds.height / 2, accuracy: 0.5)

        state.segments = [TranscriptionSegment(text: "今天下午三点讨论新版本", isConfirmed: false)]
        try await settleLayout(host)
        let expanded = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(expanded.bounds.height, 40, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.bounds.width, expanded.bounds.height)
        XCTAssertEqual(expanded.cornerRadius, expanded.bounds.height / 2, accuracy: 0.5)

        state.segments = []
        try await settleLayout(host)
        let collapsed = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(collapsed.bounds.width, 48, accuracy: 0.5)
        XCTAssertEqual(collapsed.bounds.height, collapsed.bounds.width, accuracy: 0.5)
        XCTAssertEqual(collapsed.cornerRadius, collapsed.bounds.height / 2, accuracy: 0.5)
    }

    @MainActor
    private func settleLayout(_ host: NSView) async throws {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private func findGlass(in view: NSView) -> NSGlassEffectView? {
        if let glass = view as? NSGlassEffectView { return glass }
        return view.subviews.lazy.compactMap { self.findGlass(in: $0) }.first
    }
}
