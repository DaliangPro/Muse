import SwiftUI

/// 功能页（2026-07-09 大梁老师改版）：语音输入 / AI 润色 / 语料资产各自是引导流程里的
/// 独立一页（不再是「功能速览」的子页，无圆点指示器）。
/// 版式：图标 + 大标题同一行，下一行小标题，演示区限宽定高居中。
struct SetupFeatureSlide: View {
    let index: Int

    private var titles: [(label: String, hint: String)] {
        [
            // REPAIR_PLAN J4：默认触发是 toggle（单击开始、再单击结束），不得写「按住」
            (L("语音输入", "Voice input"), L("单击快捷键说话，文字落到光标处", "Tap the hotkey, speak — text lands at the cursor")),
            (L("AI 润色", "AI polish"), L("说口语，出干净文本", "Speak casually, get clean text")),
            (L("语料资产", "Language assets"), L("说过的话自动沉淀成资产", "Your words become reusable assets")),
        ]
    }

    var body: some View {
        let item = titles[index]
        let demoHeight: CGFloat = 168

        GeometryReader { proxy in
            let topBandHeight = max(0, (proxy.size.height - demoHeight) / 2)

            ZStack(alignment: .top) {
                VStack(spacing: 6) {
                    Text(item.label)
                        .font(TF.settingsFontMetric)
                        .foregroundStyle(TF.settingsText)
                    Text(item.hint)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: topBandHeight, alignment: .center)

                Group {
                    switch index {
                    case 0: VoiceInputDemo()
                    case 1: PolishDemo()
                    default: AssetDemo()
                    }
                }
                .frame(maxWidth: 420)
                .frame(height: demoHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 子页 1 · 语音输入（真实 HUD 悬浮条演示）

private struct VoiceInputDemo: View {
    @State private var demoState = DemoState()

    var body: some View {
        // 无底板（2026-07-09 大梁老师）：HUD 条直接浮在画布上。
        // 注意 Color.clear 垫底不可省：悬浮条在演示未启动时 body 为空，SwiftUI 不给
        // 空视图触发 onAppear，而启动演示恰恰靠 onAppear——没有实体视图垫底会死锁
        // （2026-07-09 探针实锤：删掉底板矩形后动画从未启动）。
        // 环境投影补足与画布的明暗分离（深色下深条贴深底否则近乎隐形）
        ZStack {
            Color.clear
            FloatingBarView<DemoState>(state: demoState)
                .frame(maxWidth: 380)
        }
        .frame(height: TF.barHeight + TF.barOuterInset + 16)
        // 不加任何额外阴影（2026-07-09 大梁老师：要与真实一模一样）——真实悬浮窗
        // hasShadow=false，悬浮条自带内置阴影，组件本体即真实观感
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { demoState.startQuickModeDemo() }
        .onDisappear { demoState.stop() }
    }
}

// MARK: - 子页 2 · AI 润色（口语 → 干净文本）

private struct PolishDemo: View {
    private var raw: String { L("呃…这个方案我觉得吧，其实还挺不错的，就是可以再优化一下", "um… so this plan, i think, it's actually pretty good, just needs some polish") }
    private var polished: String { L("这个方案不错，可以再优化一下。", "This plan is solid and could use a bit of polish.") }

    @State private var rawReveal = 0
    @State private var polishedReveal = 0
    @State private var showPolished = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            card(label: L("你说的", "You said"),
                 text: String(raw.prefix(rawReveal)),
                 textColor: TF.settingsTextTertiary, accent: false)

            Image(systemName: "arrow.down")
                .font(TF.settingsFontIconBody)
                .foregroundStyle(TF.amber)
                .opacity(showPolished ? 1 : 0.3)

            card(label: L("输出的", "Output"),
                 text: String(polished.prefix(polishedReveal)),
                 textColor: TF.settingsText, accent: showPolished)
                .opacity(showPolished ? 1 : 0.45)
        }
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func card(label: String, text: String, textColor: Color, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(textColor.opacity(0.7))
            Text(text)
                .font(TF.settingsFontBody)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TF.settingsInnerCardCornerRadius, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TF.settingsInnerCardCornerRadius, style: .continuous)
                .strokeBorder(accent ? TF.amber.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private func start() {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                rawReveal = 0; polishedReveal = 0; showPolished = false
                for i in 1...raw.count {
                    if Task.isCancelled { return }
                    rawReveal = i
                    try? await Task.sleep(for: .milliseconds(34))
                }
                try? await Task.sleep(for: .milliseconds(450))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.3)) { showPolished = true }
                for i in 1...polished.count {
                    if Task.isCancelled { return }
                    polishedReveal = i
                    try? await Task.sleep(for: .milliseconds(34))
                }
                try? await Task.sleep(for: .seconds(2.0))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.35)) { showPolished = false; rawReveal = 0; polishedReveal = 0 }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }
}

// MARK: - 子页 3 · 语料资产（说过的话沉淀成资产）

private struct AssetDemo: View {
    private var source: String { L("我一直觉得，用户增长的关键不是拉新，而是留存。", "I keep thinking growth isn't about new users, it's about retention.") }

    @State private var sourceReveal = 0
    @State private var showQuote = false
    @State private var showTodo = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Text(String(source.prefix(sourceReveal)))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.settingsInnerCardCornerRadius, style: .continuous)
                    .fill(TF.settingsCard.opacity(0.6))
            )

            assetChip(tag: L("金句", "Quote"), text: L("增长的关键不是拉新，而是留存", "Growth is retention, not acquisition"), visible: showQuote)
            assetChip(tag: L("待办", "To-do"), text: L("整理一份留存提升清单", "Draft a retention-boost checklist"), visible: showTodo)
        }
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func assetChip(tag: String, text: String, visible: Bool) -> some View {
        HStack(spacing: 8) {
            Text(tag)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.amber)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(TF.amber.opacity(0.14)))
            Text(text)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 6)
    }

    private func start() {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                sourceReveal = 0; showQuote = false; showTodo = false
                for i in 1...source.count {
                    if Task.isCancelled { return }
                    sourceReveal = i
                    try? await Task.sleep(for: .milliseconds(38))
                }
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.32)) { showQuote = true }
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.32)) { showTodo = true }
                try? await Task.sleep(for: .seconds(2.0))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.35)) { sourceReveal = 0; showQuote = false; showTodo = false }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }
}
