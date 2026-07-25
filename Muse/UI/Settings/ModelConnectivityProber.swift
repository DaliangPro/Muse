import Foundation

extension Notification.Name {
    static let modelConnectivityProbed = Notification.Name("Muse.modelConnectivityProbed")
}

/// 启动时静默探测三个模型角色的连通性（2026-06-12 用户拍板）：
/// 结果写入 ModelConnectivityCache，打开模型设置页即见灯，无需逐个手动测试。
/// 每次应用生命周期只探一次；页面内手动测试仍可随时刷新。
@MainActor
enum ModelConnectivityProber {
    private static var didProbe = false

    static func probeOnLaunchIfNeeded() {
        guard !didProbe else { return }
        didProbe = true
        Task {
            // 等启动稳定（菜单栏/本地服务拉起）再测，不挡启动路径
            try? await Task.sleep(for: .seconds(2))
            await probeAll()
        }
    }

    static func probeAll() async {
        async let asr: Void = probeASR()
        async let llm: Void = probeLLMAndAsset()
        _ = await (asr, llm)
        AppLogger.log("[ConnectivityProber] 启动连通性探测完成")
        // 通知模型设置页刷新色点（页面可能在探测完成前就已打开）
        NotificationCenter.default.post(name: .modelConnectivityProbed, object: nil)
    }

    private static func probeASR() async {
        let provider = KeychainService.selectedASRProvider
        if provider.isLocal {
            let status = await ASRLocalModelHealthCheck.status()
            ModelConnectivityCache.asr = (provider, status)
            return
        }
        guard let config = KeychainService.loadASRConfig(for: provider),
              let client = ASRProviderRegistry.createClient(for: provider)
        else {
            ModelConnectivityCache.asr = (provider, .failed(L("待配置", "Needs setup")))
            return
        }
        do {
            try await client.connect(config: config, options: ASRRequestOptionsFactory.current(enablePunc: false))
            await client.disconnect()
            ModelConnectivityCache.asr = (provider, .success)
        } catch {
            ModelConnectivityCache.asr = (provider, .failed(ASRConnectionErrorFormatter.describe(error)))
        }
    }

    private static func probeLLMAndAsset() async {
        let llmProvider = KeychainService.selectedLLMProvider
        let llmConfig = KeychainService.loadLLMConfig()
        let llmStatus = await probeLLM(provider: llmProvider, config: llmConfig)
        if let llmConfig {
            ModelConnectivityCache.llm = LLMConnectivityCacheEntry(
                signature: LLMConnectivitySignature(provider: llmProvider, config: llmConfig),
                status: llmStatus
            )
        } else {
            ModelConnectivityCache.llm = nil
        }

        let assetProvider = KeychainService.selectedAssetExtractionLLMProvider
        let assetConfig = KeychainService.loadAssetExtractionLLMConfig()
        if let assetConfig,
           let llmConfig,
           LLMConnectivitySignature(provider: assetProvider, config: assetConfig)
            == LLMConnectivitySignature(provider: llmProvider, config: llmConfig) {
            // 完整执行配置一致时才复用，不能只按服务商复用。
            ModelConnectivityCache.asset = LLMConnectivityCacheEntry(
                signature: LLMConnectivitySignature(provider: assetProvider, config: assetConfig),
                status: llmStatus
            )
        } else {
            let status = await probeLLM(provider: assetProvider, config: assetConfig)
            if let assetConfig {
                ModelConnectivityCache.asset = LLMConnectivityCacheEntry(
                    signature: LLMConnectivitySignature(provider: assetProvider, config: assetConfig),
                    status: status
                )
            } else {
                ModelConnectivityCache.asset = nil
            }
        }
    }

    private static func probeLLM(provider: LLMProvider, config: LLMConfig?) async -> SettingsTestStatus {
        guard let config else {
            return .failed(provider == .localQwen
                ? L("本地引擎未启动", "Local engine not running")
                : L("待配置", "Needs setup"))
        }
        let client: any LLMClient = LLMProviderRegistry.makeClient(for: provider)
        let result = await LLMThinkingModeValidator.validate(
            provider: provider,
            config: config,
            client: client
        )
        switch result {
        case .valid:
            return .success
        case .adjusted(let mode, _):
            return .failed(L(
                "深度思考状态需要调整为“\(mode.displayName)”，请打开模型配置后重新测试",
                "Reasoning must be set to \(mode.displayName). Open model settings and test again."
            ))
        case .failed(let message):
            return .failed(message)
        }
    }
}
