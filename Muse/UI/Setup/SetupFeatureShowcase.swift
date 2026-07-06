import SwiftUI

/// 功能速览三子页（2026-07-06 大梁老师）：语音输入（真实 HUD 悬浮条）/ AI 润色 / 语料资产，
/// 左右箭头 + 圆点切换，每页一个真实动画演示。三页都看过后才通过 allViewed 放行「下一步」。
struct SetupFeatureShowcase: View {
    @Binding var canProceed: Bool

    @State private var page = 0

    private var titles: [(label: String, hint: String, icon: String)] {
        [
            (L("语音输入", "Voice input"), L("按住说话，文字落到光标处", "Hold, speak — text lands at the cursor"), "waveform"),
            (L("AI 润色", "AI polish"), L("说口语，出干净文本", "Speak casually, get clean text"), "wand.and.stars"),
            (L("语料资产", "Language assets"), L("说过的话自动沉淀成资产", "Your words become reusable assets"), "tray.full"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let item = titles[page]
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(item.label)
                    .font(TF.settingsFontBodyLarge)
                    .foregroundStyle(TF.settingsText)
                Text(item.hint)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer(minLength: 0)
            }

            ZStack {
                switch page {
                case 0: VoiceInputDemo()
                case 1: PolishDemo()
                default: AssetDemo()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 14) {
                Spacer()
                pagerButton("chevron.left") { move(-1) }
                    .disabled(page == 0)
                    .opacity(page == 0 ? 0.3 : 1)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i == page ? TF.amber : TF.settingsTextTertiary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                pagerButton("chevron.right") { move(1) }
                    .disabled(page == 2)
                    .opacity(page == 2 ? 0.3 : 1)
                Spacer()
            }
        }
        .onAppear { updateProceed() }
    }

    private func pagerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TF.settingsCard)
                )
        }
        .buttonStyle(.plain)
    }

    private func move(_ delta: Int) {
        let next = max(0, min(2, page + delta))
        guard next != page else { return }
        withAnimation(.easeInOut(duration: 0.22)) { page = next }
        updateProceed()
    }

    /// 大梁老师明确：只有停在第三个子页时「下一步」才可点，前两页一律不可点。
    private func updateProceed() {
        canProceed = (page == 2)
    }
}

// MARK: - 子页 1 · 语音输入（真实 HUD 悬浮条演示）

private struct VoiceInputDemo: View {
    @State private var demoState = DemoState()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 模拟桌面：随明暗切深/浅底，HUD 悬浮条真身跑在上面
            RoundedRectangle(cornerRadius: TF.settingsInnerCardCornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.86))
            FloatingBarView<DemoState>(state: demoState)
                .frame(maxWidth: 380)
        }
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

            Spacer(minLength: 0)
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

            Spacer(minLength: 0)
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
