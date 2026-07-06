import SwiftUI

struct ModelSettingsTab: View, SettingsCardHelpers {
    @State private var activeEditor: ModelSettingsEditor?
    @State private var refreshID = UUID()
    @State private var asrTestStatus: SettingsTestStatus = .idle
    @State private var llmTestStatus: SettingsTestStatus = .idle
    @State private var assetTestStatus: SettingsTestStatus = .idle
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: ModelSettingsStyle.cardSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: ModelSettingsStyle.cardSpacing) {
                    modelCards
                }

                VStack(alignment: .leading, spacing: ModelSettingsStyle.cardSpacing) {
                    modelCards
                }
            }

            LocalModelResourceStrip()
        }
        .id(refreshID)
        .onReceive(NotificationCenter.default.publisher(for: .modelConnectivityProbed)) { _ in
            // 自动探测只点亮色点（body 直读缓存），不触碰按钮状态
            refreshID = UUID()
        }
        .sheet(item: $activeEditor, onDismiss: {
            refreshID = UUID()
        }) { editor in
            ModelSettingsEditorSheet(editor: editor)
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    @ViewBuilder
    private var modelCards: some View {
        let asrSummary = ModelSettingsSummary.asr()
        let llmSummary = ModelSettingsSummary.llm()
        let assetSummary = ModelSettingsSummary.asset()

        // 色点 = 手动测试优先，否则探测缓存；按钮状态只跟手动点击走，
        // 启动自动探测不会让「测试连接」按钮出现被点击的状态（2026-06-12 用户拍板）
        ModelCapabilityCard(
            title: L("语音识别", "Speech Recognition"),
            provider: asrSummary.provider,
            model: asrSummary.model,
            statusTitle: liveStatus(asrTestStatus, cached: cachedASRStatus, summary: asrSummary).title,
            statusTone: liveStatus(asrTestStatus, cached: cachedASRStatus, summary: asrSummary).tone,
            testStatus: asrTestStatus,
            onTest: { testASRConnection() },
            onEdit: { activeEditor = .asr }
        )

        ModelCapabilityCard(
            title: L("文本处理", "Text Processing"),
            provider: llmSummary.provider,
            model: llmSummary.model,
            statusTitle: liveStatus(llmTestStatus, cached: cachedLLMStatus, summary: llmSummary).title,
            statusTone: liveStatus(llmTestStatus, cached: cachedLLMStatus, summary: llmSummary).tone,
            testStatus: llmTestStatus,
            onTest: { testLLMConnection(forAssetExtraction: false) },
            onEdit: { activeEditor = .llm }
        )

        ModelCapabilityCard(
            title: L("语料沉淀", "Corpus Extraction"),
            provider: assetSummary.provider,
            model: assetSummary.model,
            statusTitle: liveStatus(assetTestStatus, cached: cachedAssetStatus, summary: assetSummary).title,
            statusTone: liveStatus(assetTestStatus, cached: cachedAssetStatus, summary: assetSummary).tone,
            testStatus: assetTestStatus,
            onTest: { testLLMConnection(forAssetExtraction: true) },
            onEdit: { activeEditor = .asset }
        )
    }

    /// 色点显示用户真正关心的「连通状态」：手动测过→实时反馈；
    /// 否则用启动探测/弹窗回传的缓存；都没有→按配置情况给待配置/未测试
    private func liveStatus(
        _ test: SettingsTestStatus,
        cached: SettingsTestStatus?,
        summary: ModelSettingsSummaryData
    ) -> (title: String, tone: SettingsStatusTone) {
        switch test {
        case .testing:
            return (L("测试中…", "Testing…"), .neutral)
        case .success:
            return (L("连接正常", "Connected"), .success)
        case .failed:
            return (L("连接异常", "Connection failed"), .danger)
        case .idle, .saved:
            switch cached {
            case .success:
                return (L("连接正常", "Connected"), .success)
            case .failed:
                return (L("连接异常", "Connection failed"), .danger)
            default:
                return summary.statusTone == .warning
                    ? (L("待配置", "Needs setup"), .warning)
                    : (L("未测试", "Not tested"), .neutral)
            }
        }
    }

    private var cachedASRStatus: SettingsTestStatus? {
        guard let cached = ModelConnectivityCache.asr,
              cached.provider == KeychainService.selectedASRProvider else { return nil }
        return cached.status
    }

    private var cachedLLMStatus: SettingsTestStatus? {
        guard let cached = ModelConnectivityCache.llm,
              cached.provider == KeychainService.selectedLLMProvider else { return nil }
        return cached.status
    }

    private var cachedAssetStatus: SettingsTestStatus? {
        guard let cached = ModelConnectivityCache.asset,
              cached.provider == KeychainService.selectedAssetExtractionLLMProvider else { return nil }
        return cached.status
    }

}

private extension ModelSettingsTab {
    func testASRConnection() {
        testTask?.cancel()
        asrTestStatus = .testing
        let provider = KeychainService.selectedASRProvider

        testTask = Task {
            if provider.isLocal {
                let status = await ASRLocalModelHealthCheck.status()
                guard !Task.isCancelled else { return }
                recordASRStatus(status, provider: provider)
                return
            }

            do {
                guard let config = KeychainService.loadASRConfig(for: provider),
                      let client = ASRProviderRegistry.createClient(for: provider)
                else {
                    guard !Task.isCancelled else { return }
                    recordASRStatus(.failed(L("待配置", "Needs setup")), provider: provider)
                    return
                }
                try await client.connect(config: config, options: ASRRequestOptionsFactory.current(enablePunc: false))
                await client.disconnect()
                guard !Task.isCancelled else { return }
                recordASRStatus(.success, provider: provider)
            } catch {
                guard !Task.isCancelled else { return }
                recordASRStatus(.failed(ASRConnectionErrorFormatter.describe(error)), provider: provider)
            }
        }
    }

    /// 测试终态同时记入会话缓存：切页重建后色点可恢复
    func recordASRStatus(_ status: SettingsTestStatus, provider: ASRProvider) {
        asrTestStatus = status
        ModelConnectivityCache.asr = (provider, status)
    }

    func recordLLMStatus(_ status: SettingsTestStatus, provider: LLMProvider, forAssetExtraction: Bool) {
        if forAssetExtraction {
            assetTestStatus = status
            ModelConnectivityCache.asset = (provider, status)
        } else {
            llmTestStatus = status
            ModelConnectivityCache.llm = (provider, status)
        }
    }

    func testLLMConnection(forAssetExtraction: Bool) {
        testTask?.cancel()
        if forAssetExtraction {
            assetTestStatus = .testing
        } else {
            llmTestStatus = .testing
        }

        let provider = forAssetExtraction
            ? KeychainService.selectedAssetExtractionLLMProvider
            : KeychainService.selectedLLMProvider
        let config = forAssetExtraction
            ? KeychainService.loadAssetExtractionLLMConfig()
            : KeychainService.loadLLMConfig()

        testTask = Task {
            do {
                guard let config else {
                    guard !Task.isCancelled else { return }
                    // localQwen 的 config 为 nil 通常是本地引擎没在跑，而非没配置
                    let message = provider == .localQwen
                        ? L("本地引擎未启动", "Local engine not running")
                        : L("待配置", "Needs setup")
                    recordLLMStatus(.failed(message), provider: provider, forAssetExtraction: forAssetExtraction)
                    return
                }

                let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)
                let reply = try await client.process(text: "hi", prompt: "{text}", config: config)
                guard !Task.isCancelled else { return }
                recordLLMStatus(.success, provider: provider, forAssetExtraction: forAssetExtraction)
                AppLogger.log("[Settings] Model summary LLM test OK (\(provider.rawValue)) replyLen=\(reply.count)")
            } catch {
                guard !Task.isCancelled else { return }
                recordLLMStatus(.failed(error.localizedDescription), provider: provider, forAssetExtraction: forAssetExtraction)
                AppLogger.log("[Settings] Model summary LLM test failed (\(provider.rawValue)): \(String(describing: error))")
            }
        }
    }
}
