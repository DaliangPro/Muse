import AppKit
import Foundation

@MainActor
enum AppStartupCoordinator {
    static func configureActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: DefaultsKeys.showDockIcon) as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    static func runMigrations() {
        KeychainService.migrateIfNeeded()
        HotwordStorage.migrateIfNeeded()
        SnippetStorage.migrateIfNeeded()
        removeOrphanHistoryFileIfNeeded()
    }

    /// REPAIR_PLAN C1：清理历史遗留的 0 字节孤儿库文件 history.sqlite
    /// （代码早已只用 history.db）。仅在文件为空时移入废纸篓，绝不动有内容的文件
    private static func removeOrphanHistoryFileIfNeeded() {
        let orphan = AppPaths.supportDir.appendingPathComponent("history.sqlite")
        let fm = FileManager.default
        guard fm.fileExists(atPath: orphan.path),
              let size = (try? fm.attributesOfItem(atPath: orphan.path))?[.size] as? NSNumber,
              size.intValue == 0 else { return }
        try? fm.trashItem(at: orphan, resultingItemURL: nil)
        AppLogger.log("[App] 已清理 0 字节孤儿文件 history.sqlite（移入废纸篓）")
    }

    static func scheduleDebugWindowsIfNeeded(
        hudDebugPresenter: HUDDebugPresenter,
        appState: AppState,
        openSettingsWindow: @escaping @MainActor () -> Void
    ) {
        if AppLaunchDebug.hudDemoEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    hudDebugPresenter.showHUDDebugWindow()
                }
            }
        }

        if AppLaunchDebug.floatingHUDDemoEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    hudDebugPresenter.showFloatingHUDDebugDemo(appState: appState)
                }
            }
        }

        if AppLaunchDebug.settingsPreviewEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    openSettingsWindow()
                }
            }
        }
    }

    static func showSetupWizardIfNeeded(appState: AppState) {
        guard !AppLaunchDebug.hudDemoEnabled, !appState.hasCompletedSetup else { return }
        attemptOpenSetupWizard(retriesLeft: 20)
    }

    /// openSetupAction 由菜单栏视图渲染时注册，可能晚于本次调用；为 nil 时按 0.3s 间隔重试，
    /// 直到注册就绪再开窗——消除「首次启动偶发不弹引导」的时序竞态。用与菜单栏「使用引导」
    /// 相同的 openWindow 机制；耗尽重试才退回失效的 sendAction 兜底。
    private static func attemptOpenSetupWizard(retriesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                if let openSetup = AppDelegate.openSetupAction {
                    openSetup()
                    NSApp.activate(ignoringOtherApps: true)
                } else if retriesLeft > 0 {
                    attemptOpenSetupWizard(retriesLeft: retriesLeft - 1)
                } else {
                    _ = NSApp.sendAction(Selector(("showSetupWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    static func startLocalServerIfNeeded() {
        // 三类模型角色任一选了本地引擎都需要拉起本地服务：
        // 识别（sherpa）、润色（localQwen）、语料提炼（localQwen）——
        // 此前漏了第三个，导致只有提炼用本地模型时服务不启动、提炼必失败
        let needsLocalServer = KeychainService.selectedASRProvider == .sherpa
            || KeychainService.selectedLLMProvider == .localQwen
            || KeychainService.selectedAssetExtractionLLMProvider == .localQwen
        guard needsLocalServer else { return }

        if ModelManager.isLocalASRModelAvailable || LocalQwenLLMConfig.isModelAvailable {
            Task {
                do {
                    try await SenseVoiceServerManager.shared.start()
                } catch {
                    AppLogger.log("[App] SenseVoice server start failed: \(String(describing: error))")
                }
            }
        } else if KeychainService.selectedASRProvider == .sherpa {
            AppLogger.log("[App] Local ASR not available (cloud build), switching to volcano")
            KeychainService.selectedASRProvider = .volcano
        }

        // 润色/提炼选了本地千问但模型未下载时，服务即使为 ASR 拉起也无法服务 LLM，
        // 此前会静默失败。这里独立告警，避免运行时润色/提炼无声出错。
        if !LocalQwenLLMConfig.isModelAvailable {
            if KeychainService.selectedLLMProvider == .localQwen {
                AppLogger.log("[App] Local Qwen LLM model not downloaded; polish will fail until the model is downloaded")
            }
            if KeychainService.selectedAssetExtractionLLMProvider == .localQwen {
                AppLogger.log("[App] Local Qwen LLM model not downloaded; asset extraction will fail until the model is downloaded")
            }
        }
    }
}
