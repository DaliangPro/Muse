import AppKit
import SwiftUI

struct MenuBarContent: View {

    @Environment(\.openWindow) private var openWindow
    @AppStorage(DefaultsKeys.language) private var language = AppLanguage.systemSelection

    var body: some View {
        Button(L("设置", "Settings")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(L("使用引导", "Setup Guide")) {
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(L("关于", "About")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.about)
        }

        Button(L("检查更新", "Check for Updates")) {
            showUpdatePlaceholder()
        }

        Divider()

        Button(L("退出 Muse", "Quit Muse")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // 语言变化时强制重渲染
        let _ = language

        // 注册 Dock 图标点击打开设置
        let _ = {
            AppDelegate.openSettingsAction = { [openWindow] in
                openWindow(id: "settings")
            }
            AppDelegate.openSetupAction = { [openWindow] in
                openWindow(id: "setup")
            }
        }()
    }

    /// 检查更新随正式发布开放（当前 UpdateChecker.updateChannelEnabled=false，更新源仓库尚未发布）；
    /// 在此之前点击给出友好提示（2026-06-22 大梁老师拍板）
    private func showUpdatePlaceholder() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("检查更新", "Check for Updates")
        alert.informativeText = L("更新功能将随正式发布开放，敬请期待。",
                                  "Update checking will be available with the official release.")
        alert.addButton(withTitle: L("好的", "OK"))
        alert.runModal()
    }
}
