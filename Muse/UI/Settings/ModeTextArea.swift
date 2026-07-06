import AppKit
import SwiftUI

struct ModeTextArea: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    /// 打字区底色：比卡片(settingsCardAlt)深约 0.05，对齐 settingsDropdownTriggerFill，深浅自适应
    static let inputFieldBackground = NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.isDark {
            return NSColor(srgbRed: 0.123, green: 0.123, blue: 0.123, alpha: 1)
        }
        return NSColor(srgbRed: 0.938, green: 0.935, blue: 0.928, alpha: 1)
    })

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // 打字区底色比卡片深一档、让用户一眼看出可输入区域；卡片背景保持不动（2026-06-25 大梁老师）
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ModeTextArea.inputFieldBackground
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 7
        scrollView.layer?.masksToBounds = true
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = isEditable
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        applyStyle(to: textView)
        context.coordinator.lastAppliedStyleKey = currentStyleKey(for: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        syncTextIfNeeded(in: scrollView, textView: textView, coordinator: context.coordinator)

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.allowsUndo != isEditable {
            textView.allowsUndo = isEditable
        }

        let styleKey = currentStyleKey(for: textView)
        if context.coordinator.lastAppliedStyleKey != styleKey {
            preserveScrollPosition(in: scrollView) {
                applyStyle(to: textView)
            }
            context.coordinator.lastAppliedStyleKey = styleKey
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let font = TF.settingsNSFontReading
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6

        textView.font = font
        textView.textColor = NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.isDark {
                return NSColor(
                    srgbRed: 0.72,
                    green: 0.75,
                    blue: 0.80,
                    alpha: 1
                )
            }
            return NSColor(
                srgbRed: 0.27,
                green: 0.30,
                blue: 0.35,
                alpha: 1
            )
        })
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textView.textColor ?? NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    private func syncTextIfNeeded(
        in scrollView: NSScrollView,
        textView: NSTextView,
        coordinator: Coordinator
    ) {
        guard textView.string != text else { return }

        let visibleOrigin = scrollView.contentView.bounds.origin
        let selectedRanges = textView.selectedRanges
        coordinator.isApplyingProgrammaticTextUpdate = true
        textView.string = text
        coordinator.isApplyingProgrammaticTextUpdate = false

        restoreSelectedRanges(selectedRanges, in: textView)
        restoreScrollOrigin(visibleOrigin, in: scrollView)
    }

    private func preserveScrollPosition(
        in scrollView: NSScrollView,
        operation: () -> Void
    ) {
        let visibleOrigin = scrollView.contentView.bounds.origin
        operation()
        restoreScrollOrigin(visibleOrigin, in: scrollView)
    }

    private func restoreScrollOrigin(_ origin: NSPoint, in scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        if let textView = scrollView.documentView as? NSTextView,
           let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentHeight - visibleHeight)
        let restoredOrigin = NSPoint(
            x: origin.x,
            y: min(max(origin.y, 0), maxY)
        )
        scrollView.contentView.scroll(to: restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreSelectedRanges(_ ranges: [NSValue], in textView: NSTextView) {
        let textLength = (textView.string as NSString).length
        let validRanges = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(range.location, textLength)
            let length = min(range.length, max(0, textLength - location))
            return NSValue(range: NSRange(location: location, length: length))
        }
        guard !validRanges.isEmpty else { return }
        textView.selectedRanges = validRanges
    }

    private func currentStyleKey(for textView: NSTextView) -> StyleKey {
        StyleKey(
            appearanceName: textView.effectiveAppearance.name.rawValue
        )
    }

    struct StyleKey: Equatable {
        let appearanceName: String
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ModeTextArea
        var isApplyingProgrammaticTextUpdate = false
        var lastAppliedStyleKey: StyleKey?

        init(_ parent: ModeTextArea) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticTextUpdate else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
