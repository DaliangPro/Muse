import SwiftUI
import AVFoundation
import ApplicationServices

/// 使用引导（2026-07-06 大梁老师重构 · 方向 A 侧栏式，严格复用项目设计系统）：
/// 侧栏复刻 SettingsSidebarView 的「墨色一体 + 纯文字 + 琥珀竖线选中」语言，
/// 内容区全用 TF token 与项目字号档（最大 24pt light），克制间距。
/// 5 屏：欢迎 → 功能速览 → 授权 → 识别引擎介绍 → 就绪。引擎只介绍不配置，触发键随模式动态。
struct SetupWizardView: View {

    @Environment(AppState.self) private var appState
    @State private var step = 0
    // 初始即读真实授权态：避免进授权页时 false→true 的跳变被切页动画捕捉（每次进入动画不一）
    @State private var hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var overviewCanProceed = false
    @AppStorage(DefaultsKeys.language) private var language = AppLanguage.systemSelection
    @AppStorage("tf_settingsAppearance") private var appearanceSelection = SettingsAppearanceMode.system.rawValue

    private let sidebarWidth = SettingsLayout.sidebarWidth        // 136
    private let navControlWidth = SettingsSidebarLayout.controlWidth  // 112
    private let leadingInset = SettingsSidebarLayout.leadingInset     // 12

    private var stepTitles: [String] {
        [
            L("欢迎", "Welcome"),
            L("功能速览", "Overview"),
            L("授权", "Permissions"),
            L("识别引擎", "Engines"),
            L("就绪", "Ready"),
        ]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            rightContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(fullBleedBackground)
        .background(SetupWindowChrome())
        .id(language)
    }

    /// 左右分色的满溢背景：铺到窗口所有边缘（含标题栏与底部）。无论窗口尺寸是否与内容
    /// 完全吻合，露出的边缘都是该列本该有的底色（左=侧栏色，右=画布色），杜绝异色边条。
    private var fullBleedBackground: some View {
        HStack(spacing: 0) {
            TF.settingsSidebarTint
                .frame(width: sidebarWidth)
            TF.settingsCanvas
        }
        .ignoresSafeArea()
    }

    // MARK: - 左侧步骤栏（复刻墨色一体 · 纯文字 · 琥珀竖线）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Muse")
                .font(TF.settingsFontBodyStrong)
                .foregroundStyle(TF.settingsSidebarSelectionText)
                .padding(.leading, leadingInset + SettingsSidebarLayout.navTextLeadingInset)
                .padding(.top, SettingsSidebarLayout.navTopInset)

            VStack(spacing: SettingsSidebarLayout.navItemSpacing) {
                ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                    stepRow(index: index, title: title)
                }
            }
            .padding(.leading, leadingInset)
            .padding(.top, 20)

            Spacer(minLength: 0)

            SetupAppearanceToggle(selection: $appearanceSelection)
                .padding(.leading, leadingInset + SettingsSidebarLayout.navTextLeadingInset)
                .padding(.bottom, 18)
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(TF.settingsSidebarTint)
    }

    private func stepRow(index: Int, title: String) -> some View {
        let isCurrent = index == step
        let isDone = index < step
        let foreground: Color = isCurrent
            ? TF.settingsSidebarSelectionText
            : (isDone ? TF.settingsSidebarText : TF.settingsSidebarText.opacity(0.5))
        let shape = RoundedRectangle(cornerRadius: SettingsSidebarLayout.navItemCornerRadius, style: .continuous)

        return HStack(spacing: 0) {
            Text(title)
                .font(TF.settingsFontNavigation)
                .foregroundStyle(foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsSidebarLayout.navTextLeadingInset)
        .padding(.trailing, 12)
        .frame(width: navControlWidth, height: SettingsSidebarLayout.navItemHeight, alignment: .leading)
        .background(shape.fill(isCurrent ? TF.settingsSidebarActiveFill : Color.clear))
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1)
                    .fill(TF.amber)
                    .frame(width: 2, height: 14)
                    .offset(x: -leadingInset)
            }
        }
    }

    // MARK: - 右侧内容区

    private var rightContent: some View {
        ZStack {
            TF.settingsCanvas
            Group {
                switch step {
                case 0: welcomeScreen
                case 1: overviewScreen
                case 2: permissionsScreen
                case 3: enginesScreen
                default: readyScreen
                }
            }
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: step)
        .clipped()
    }

    @ViewBuilder
    private func scaffold<C: View>(
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        primaryDisabled: Bool = false,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TF.settingsFontMetric)
                    .foregroundStyle(TF.settingsText)
                if let subtitle {
                    Text(subtitle)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
                .padding(.top, 22)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                if step > 0 {
                    SettingsTextButton(L("上一步", "Back"), variant: .secondary, onCanvas: true, action: back)
                }
                Spacer()
                SettingsTextButton(primaryTitle, variant: .primary, minWidth: 72, action: advance)
                    .disabled(primaryDisabled)
                    .opacity(primaryDisabled ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Screen 0 · Welcome

    private var welcomeScreen: some View {
        scaffold(
            title: L("你的灵感缪斯", "Your creative Muse"),
            subtitle: L("按住说话、松手成文的语音输入法，也是帮你随手留住灵感、随时取用的工作台。",
                        "A voice keyboard that turns speech into text — and a workbench that keeps every idea within reach."),
            primaryTitle: L("开始", "Get Started")
        ) {
            HStack(spacing: 6) {
                ForEach(["中文", "English", "粤语", "日本語", "한국어"], id: \.self) { lang in
                    Text(lang)
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(TF.settingsCard))
                }
            }
        }
    }

    // MARK: - Screen 1 · Feature Overview

    private var overviewScreen: some View {
        scaffold(
            title: L("Muse 能帮你做什么", "What Muse can do"),
            subtitle: L("Muse 的三大核心功能", "The three core features of Muse"),
            primaryTitle: L("下一步", "Next"),
            primaryDisabled: !overviewCanProceed
        ) {
            SetupFeatureShowcase(canProceed: $overviewCanProceed)
        }
    }

    // MARK: - Screen 2 · Permissions

    private var permissionsScreen: some View {
        scaffold(
            title: L("授予权限", "Grant permissions"),
            subtitle: L("两项系统权限，缺一不可", "Two system permissions, both required"),
            primaryTitle: L("下一步", "Next")
        ) {
            VStack(spacing: TF.settingsCardSpacing) {
                permissionRow(
                    icon: "mic",
                    title: L("麦克风", "Microphone"),
                    granted: hasMic
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in hasMic = granted }
                    }
                }
                permissionRow(
                    icon: "keyboard",
                    title: L("辅助功能", "Accessibility"),
                    granted: hasAccessibility
                ) {
                    PermissionManager.promptAccessibilityPermission()
                    PermissionManager.openAccessibilitySettings()
                }

                if !hasAccessibility {
                    Text(L("在系统设置里找到 Muse 打开开关；若已开启快捷键仍无效，请重启 App。",
                           "Toggle Muse ON in System Settings. If hotkeys still fail after enabling, restart the app."))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 20)

            Text(title)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)

            Spacer(minLength: 8)

            if granted {
                Text(L("已授权", "Granted"))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsAccentGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(TF.settingsAccentGreen.opacity(0.15)))
            } else {
                Button(action: action) {
                    Text(L("去授权", "Grant"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(Color(red: 0.22, green: 0.14, blue: 0.02))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(TF.amber))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: TF.settingsInnerCardCornerRadius, style: .continuous)
                .fill(TF.settingsCard)
        )
    }

    // MARK: - Screen 3 · Recognition Engines (介绍，不配置)

    private var enginesScreen: some View {
        scaffold(
            title: L("三种识别引擎", "Recognition engines"),
            subtitle: L("先用开箱即用的，之后随时换", "Start with the zero-setup one, switch anytime"),
            primaryTitle: L("下一步", "Next")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                engineRow("laptopcomputer",
                          L("Apple 本机", "Apple on-device"),
                          L("零配置、隐私、开箱即用", "Zero setup, private, ready to go"),
                          recommended: true)
                engineRow("cloud",
                          L("火山云端", "Volcano cloud"),
                          L("高精度，需填 API 凭据", "High accuracy, needs an API key"),
                          recommended: false)
                engineRow("internaldrive",
                          L("本地离线（SenseVoice + Qwen3）", "Local (SenseVoice + Qwen3)"),
                          L("离线、Apple Silicon，需下载模型", "Offline, Apple Silicon, model download"),
                          recommended: false)

                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(TF.settingsFontIconBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(L("以上可在 设置 → 模型配置 里切换与配置", "Switch and configure in Settings → Model Config"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .padding(.top, 2)
            }
        }
    }

    private func engineRow(_ icon: String, _ name: String, _ detail: String, recommended: Bool) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(recommended ? TF.amber : TF.settingsTextSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(TF.settingsFontBodyLarge)
                        .foregroundStyle(TF.settingsText)
                    if recommended {
                        Text(L("新手推荐", "Recommended"))
                            .font(TF.settingsFontMetadata)
                            .foregroundStyle(TF.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(TF.amber.opacity(0.14)))
                    }
                }
                Text(detail)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Screen 4 · Ready

    private var readyScreen: some View {
        scaffold(
            title: L("准备就绪", "All set"),
            primaryTitle: L("开始使用", "Start Using")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(TF.settingsFontIconControl)
                        .foregroundStyle(TF.success)
                    Text(L("设置完成，可以开始了", "Setup complete"))
                        .font(TF.settingsFontBodyLarge)
                        .foregroundStyle(TF.settingsText)
                }
                Text(usageText)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("更多设置在菜单栏 Muse 图标 → 设置", "More options: menu bar Muse → Settings"))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
    }

    // MARK: - Navigation & Logic

    private func advance() {
        if step < 4 {
            withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
        } else {
            finishSetup()
        }
    }

    private func back() {
        guard step > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) { step -= 1 }
    }

    private func refreshPermissions() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    /// 引导给新用户看的是产品默认快捷键（右 Option 单击 toggle），不读用户个人配置。
    private var usageText: String {
        L(
            "单击 Option（⌥）开始说话，再单击 Option 结束，文字自动输入到光标位置。",
            "Press Option (⌥) to start speaking, press again to stop — text lands at the cursor."
        )
    }

    private func finishSetup() {
        applyDefaultEngineFallbackIfNeeded()
        appState.hasCompletedSetup = true
        // 先记住引导窗口，打开设置窗口、再关引导——「开始使用」顺势落到设置页，而非凭空消失
        let setupWindow = NSApp.keyWindow
        AppDelegate.openSettingsAction?()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.close()
        // 重置到第一步：下次从菜单再点「使用引导」时从欢迎页开始
        step = 0
    }

    /// 新手兜底：完成引导时若默认引擎仍是火山且无可用凭据，落到零配置的 Apple 本机，
    /// 保证「只介绍不配置」路线下第一句话也能出。用户若已选别的引擎则尊重不动。
    private func applyDefaultEngineFallbackIfNeeded() {
        guard KeychainService.selectedASRProvider == .volcano else { return }
        let creds = KeychainService.loadASRCredentials(for: .volcano) ?? [:]
        let hasVolcanoCreds = !(creds["appKey"] ?? "").isEmpty && !(creds["accessKey"] ?? "").isEmpty
        if !hasVolcanoCreds {
            KeychainService.selectedASRProvider = .apple
        }
    }
}

// MARK: - 窗口外观：内容延伸到标题栏，消除顶部露出的默认底色（墨绿栏）

private struct SetupWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SetupWindowChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SetupWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 延迟一拍等 SwiftUI 完成窗口初始化，再锁定，避免被覆盖
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(TF.settingsShell)
            // 锁死窗口内容尺寸 = 内容尺寸：窗口不再比内容高出一截，底部空当消失
            let size = NSSize(width: 700, height: 520)
            window.setContentSize(size)
            window.contentMinSize = size
            window.contentMaxSize = size
        }
    }
}

// MARK: - 深浅色两档开关（浅色 / 深色，无描边，靠填充与侧栏区分）

private struct SetupAppearanceToggle: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme

    /// 当前应高亮深色档吗：显式选了 dark 则是；light 则否；其余（含旧 system）看实际外观
    private var isDark: Bool {
        SettingsAppearanceMode.resolvedIsDark(selection: selection, systemColorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 18) {
            iconButton("sun.max", active: !isDark, mode: .light)
            iconButton("moon", active: isDark, mode: .dark)
        }
    }

    private func iconButton(_ icon: String, active: Bool, mode: SettingsAppearanceMode) -> some View {
        Button {
            selection = mode.rawValue
            AppearanceController.apply()
        } label: {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(active ? TF.amber : TF.settingsSidebarText.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
