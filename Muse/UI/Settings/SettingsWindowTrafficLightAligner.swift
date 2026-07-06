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

        let closeFrame = closeButton.frame
        let minimizeFrame = minimizeButton.frame
        let zoomFrame = zoomButton.frame
        let minimizeOffset = minimizeFrame.minX - closeFrame.minX
        let zoomOffset = zoomFrame.minX - closeFrame.minX
        let targetY: CGFloat
        if let buttonContainer = closeButton.superview {
            targetY = buttonContainer.bounds.height - topInset - closeFrame.height
        } else {
            targetY = closeFrame.minY
        }

        closeButton.setFrameOrigin(NSPoint(x: leadingInset, y: targetY))
        minimizeButton.setFrameOrigin(NSPoint(x: leadingInset + minimizeOffset, y: targetY))
        zoomButton.setFrameOrigin(NSPoint(x: leadingInset + zoomOffset, y: targetY))
        alignToWindowEdges(
            in: window,
            closeButton: closeButton,
            minimizeButton: minimizeButton,
            zoomButton: zoomButton
        )
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

    private func alignToWindowEdges(
        in window: NSWindow,
        closeButton: NSButton,
        minimizeButton: NSButton,
        zoomButton: NSButton
    ) {
        let closeScreenRect = window.convertToScreen(closeButton.convert(closeButton.bounds, to: nil))
        let desiredButtonLeft = window.frame.minX + leadingInset
        let desiredButtonTop = window.frame.maxY - topInset
        let xDelta = desiredButtonLeft - closeScreenRect.minX
        let yDelta = desiredButtonTop - closeScreenRect.maxY
        guard abs(xDelta) >= 0.5 || abs(yDelta) >= 0.5 else { return }

        [closeButton, minimizeButton, zoomButton].forEach { button in
            button.setFrameOrigin(NSPoint(x: button.frame.minX + xDelta, y: button.frame.minY + yDelta))
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
