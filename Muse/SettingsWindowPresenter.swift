import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    private var manualSettingsWindow: NSWindow?

    func open(
        preferManualWindow: Bool = false,
        appState: AppState,
        appUpdater: AppUpdater,
        swiftUIOpenAction: (() -> Void)?
    ) {
        NSApp.setActivationPolicy(.regular)

        if !preferManualWindow, let swiftUIOpenAction {
            DebugFileLogger.log("openSettingsWindow: SwiftUI openWindow action")
            swiftUIOpenAction()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let manualSettingsWindow {
            DebugFileLogger.log("openSettingsWindow: reuse manual window")
            manualSettingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        DebugFileLogger.log("openSettingsWindow: create manual window")
        let settingsView = SettingsView(configuresWindow: true)
            .environment(appState)
            .environment(appUpdater)
            .frame(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        DebugFileLogger.log("openSettingsWindow: build hosting controller")
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsLayout.windowContentWidth,
            height: SettingsLayout.windowContentHeight
        )
        DebugFileLogger.log("openSettingsWindow: hosting controller ready")
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayout.windowContentWidth,
                height: SettingsLayout.windowContentHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        DebugFileLogger.log("openSettingsWindow: nswindow ready")
        window.title = L("Muse 设置", "Muse Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        // 初始外观跟随「设置」偏好，避免窗口首帧用系统/默认外观（常为深色）、要点一下才刷成浅色
        // （2026-06-22 修复；与 SettingsPopupDropdown 同款做法）
        let appearanceMode = SettingsAppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "tf_settingsAppearance") ?? ""
        ) ?? .system
        let initialIsDark: Bool
        switch appearanceMode.preferredColorScheme {
        case .dark: initialIsDark = true
        case .light: initialIsDark = false
        default: initialIsDark = NSApp.effectiveAppearance.isDark
        }
        let initialAppearance = NSAppearance(named: initialIsDark ? .darkAqua : .aqua)
        window.appearance = initialAppearance
        hostingController.view.appearance = initialAppearance
        DebugFileLogger.log("openSettingsWindow: content controller assigned")
        window.setContentSize(
            NSSize(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        manualSettingsWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
            guard let self, let window else { return }
            MainActor.assumeIsolated {
                window.setContentSize(
                    NSSize(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
                )
                window.center()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                DebugFileLogger.log("openSettingsWindow: manual frame=\(window.frame)")
                self.manualSettingsWindow = window
            }
        }
    }
}
