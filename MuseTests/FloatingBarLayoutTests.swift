import AppKit
import SwiftUI
import XCTest
@testable import Muse

final class FloatingBarLayoutTests: XCTestCase {
    @MainActor
    func testIncomingEdgeFadesBeforeAndAfterOverflow() throws {
        for overflow in [false, true] {
            let view = Color.red
                .frame(width: 100, height: 40)
                .mask(HUDTextEdgeMask(leadingFadeWidth: 4, trailingFadeWidth: 14,
                                      hasLeadingOverflow: overflow))
            let pixels = try renderPixels(view, width: 100, height: 40)
            let alpha = { (x: Int) in pixels[(20 * 100 + x) * 4 + 3] }
            XCTAssertGreaterThan(alpha(70), 250)
            XCTAssertGreaterThan(alpha(88), alpha(94))
            XCTAssertGreaterThan(alpha(94), alpha(99))
            XCTAssertLessThan(alpha(99), 30, "新字进入的一侧应渐隐，而非硬裁切")
            if overflow {
                XCTAssertLessThan(alpha(0), 80, "旧文字离开的一侧应渐隐")
            } else {
                XCTAssertGreaterThan(alpha(0), 250, "短文本的开头应保持清晰")
            }
        }
    }

    @MainActor
    func testStreamingTextStaysInsideNarrowAndWideViewports() throws {
        for width in [20, 80, 360] {
            for text in ["今天", String(repeating: "连续输入ABC", count: 20) + "最新尾部"] {
                let view = StreamingHUDText(text: text, color: .red, leadingFadeWidth: 4)
                    .frame(width: CGFloat(width), height: 40)
                    .frame(width: 600, height: 80)
                let pixels = try renderPixels(view, width: 600, height: 80)
                let left = (600 - width) / 2
                var inside = 0
                var outside = 0
                for y in 0..<80 {
                    for x in 0..<600 where isRed(pixels, x: x, y: y, width: 600) {
                        if (left..<(left + width)).contains(x) && (20..<60).contains(y) { inside += 1 }
                        else { outside += 1 }
                    }
                }
                XCTAssertGreaterThan(inside, 5, "视窗内应保留可见文字")
                XCTAssertEqual(outside, 0, "文字及其阴影不可越过视窗")
            }
        }
    }

    @MainActor
    func testGlassClipsOversizedContentToTheCurrentShell() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("原生玻璃需要 macOS 26") }
        let view = CleanGlassCapsule(
            cornerRadius: 20, style: .regular, tintColor: nil,
            content: AnyView(Color.red.frame(width: 160, height: 60))
        )
        .frame(width: 40, height: 40)
        .frame(width: 200, height: 100)
        let pixels = try renderPixels(view, width: 200, height: 100)
        var inside = 0
        var outside = 0
        for y in 0..<100 {
            for x in 0..<200 where isRed(pixels, x: x, y: y, width: 200) {
                if (80..<120).contains(x) && (30..<70).contains(y) { inside += 1 }
                else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 500, "确认内容实际被绘制，避免空图误判通过")
        XCTAssertEqual(outside, 0, "当前玻璃边界外不应出现内容像素")
    }

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
    func testCircleAndExpandedBarKeepTheSameHeightAndCenterLine() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("原生玻璃需要 macOS 26")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousRegistration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["museGlassMinimal": true])
        defer { defaults.setVolatileDomain(previousRegistration, forName: UserDefaults.registrationDomain) }

        let state = DemoState()
        state.barPhase = .preparing
        let host = NSHostingView(rootView: FloatingBarView(state: state)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 180)

        try await settleLayout(host)
        let preparing = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(preparing.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(preparing.bounds.height, preparing.bounds.width, accuracy: 0.5)
        XCTAssertEqual(preparing.cornerRadius, 20, accuracy: 0.5)
        let sharedHeight = preparing.bounds.height
        let sharedCenterY = preparing.convert(preparing.bounds, to: host).midY

        state.barPhase = .recording
        try await settleLayout(host)
        let initial = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(initial.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(initial.bounds.height, initial.bounds.width, accuracy: 0.5)
        XCTAssertEqual(initial.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(initial.convert(initial.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertEqual(initial.cornerRadius, initial.bounds.height / 2, accuracy: 0.5)

        state.segments = [TranscriptionSegment(text: "今天下午三点讨论新版本", isConfirmed: false)]
        try await settleLayout(host)
        let expanded = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(expanded.bounds.height, 40, accuracy: 0.5)
        XCTAssertEqual(expanded.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(expanded.convert(expanded.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.bounds.width, expanded.bounds.height)
        XCTAssertEqual(expanded.cornerRadius, expanded.bounds.height / 2, accuracy: 0.5)

        state.segments = []
        try await settleLayout(host)
        let collapsed = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(collapsed.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(collapsed.bounds.height, collapsed.bounds.width, accuracy: 0.5)
        XCTAssertEqual(collapsed.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(collapsed.convert(collapsed.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertEqual(collapsed.cornerRadius, collapsed.bounds.height / 2, accuracy: 0.5)
    }

    @MainActor
    private func settleLayout(_ host: NSView) async throws {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    private func renderPixels<V: View>(_ view: V, width: Int, height: Int) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private func isRed(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> Bool {
        let offset = (y * width + x) * 4
        return pixels[offset] > 150 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80 && pixels[offset + 3] > 150
    }

    @available(macOS 26.0, *)
    @MainActor
    private func findGlass(in view: NSView) -> NSGlassEffectView? {
        if let glass = view as? NSGlassEffectView { return glass }
        return view.subviews.lazy.compactMap { self.findGlass(in: $0) }.first
    }
}
