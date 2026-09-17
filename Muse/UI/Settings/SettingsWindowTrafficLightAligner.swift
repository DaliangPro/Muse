import AppKit

struct SettingsWindowTrafficLightAligner {
    let leadingInset: CGFloat
    let topInset: CGFloat

    func align(in window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton)
        else { return }

        let closeScreenRect = window.convertToScreen(closeButton.convert(closeButton.bounds, to: nil))
        let xDelta = window.frame.minX + leadingInset - closeScreenRect.minX
        let yDelta = window.frame.maxY - topInset - closeScreenRect.maxY

        // 全尺寸内容视图可能被 SwiftUI 排在标题栏之上，保持原生按钮所在容器位于内容上方。
        if let frameView = window.contentView?.superview {
            var titlebar: NSView = closeButton
            while let parent = titlebar.superview, parent !== frameView { titlebar = parent }
            if titlebar.superview === frameView, frameView.subviews.last !== titlebar {
                frameView.addSubview(titlebar, positioned: .above, relativeTo: nil)
            }
        }

        for button in [closeButton, minimizeButton, zoomButton] {
            guard let container = button.superview else { continue }
            let desiredY = button.frame.minY + yDelta
            let minimumY = container.bounds.minY
            let maximumY = container.bounds.maxY - button.frame.height
            // SwiftUI 的标题栏可能只有 28pt；16pt 顶距会把按钮移到容器外。
            // 空间不足时使用原生容器的垂直中心，不能以窗口边缘对齐覆盖此约束。
            let targetY = (minimumY...max(minimumY, maximumY)).contains(desiredY)
                ? desiredY
                : max(minimumY, container.bounds.midY - button.frame.height / 2)
            button.setFrameOrigin(NSPoint(x: button.frame.minX + xDelta, y: targetY))
        }
    }

    func alignAfterSystemLayout(in window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
    }


}

final class SettingsWindowTrafficLightAlignmentObserver {
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var aligner: SettingsWindowTrafficLightAligner?

    deinit {
        detach()
    }

    func attach(to window: NSWindow, aligner: SettingsWindowTrafficLightAligner) {
        self.aligner = aligner

        if observedWindow !== window {
            detach()
            observedWindow = window
            addObservers(to: window)
        }

        realign(in: window)
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observedWindow = nil
    }

    private func addObservers(to window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didBecomeKeyNotification
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.realign(in: window)
            }
        }
    }

    private func realign(in window: NSWindow) {
        guard let aligner else { return }
        aligner.align(in: window)
        aligner.alignAfterSystemLayout(in: window)
    }
}
