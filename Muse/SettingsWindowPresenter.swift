import AppKit
import SwiftUI

/// 设置窗口只由SwiftUI场景创建；菜单和Dock复用同一个打开动作。
@MainActor
final class SettingsWindowPresenter {
    private var openAction: (() -> Void)?
    private var pendingOpen = false

    func register(openAction: @escaping () -> Void) {
        self.openAction = openAction
        if pendingOpen {
            pendingOpen = false
            open()
        }
    }

    func open() {
        guard let openAction else {
            pendingOpen = true
            return
        }
        NSApp.setActivationPolicy(.regular)
        openAction()
        NSApp.activate(ignoringOtherApps: true)
        DebugFileLogger.log("openSettingsWindow: single SwiftUI settings scene")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let visibleCount = NSApp.windows.filter {
                $0.identifier?.rawValue == "settings" && $0.isVisible
            }.count
            DebugFileLogger.log("openSettingsWindow: visible settings count=\(visibleCount)")
        }
    }
}

/// 命令菜单在窗口关闭后仍存在，可为菜单栏与Dock持续提供openWindow动作。
struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow
    let register: (@escaping () -> Void) -> Void
    let open: () -> Void

    var body: some View {
        let _ = register { openWindow(id: "settings") }
        Button(L("设置…", "Settings…"), action: open)
            .keyboardShortcut(",", modifiers: .command)
    }
}
