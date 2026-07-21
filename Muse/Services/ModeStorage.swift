import Foundation

struct ModeStorage {

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            self.fileURL = AppPaths.ensureSupportDir().appendingPathComponent("modes.json")
        }
    }

    func save(_ modes: [ProcessingMode]) throws {
        try JSONFileStore.writeOrThrow(modes, to: fileURL)
    }

    /// 核心读取：保留 missing / value / corrupt 三态，供设置页决定是否进入恢复流程。
    func loadResult() -> JSONFileReadResult<[ProcessingMode]> {
        JSONFileStore.read([ProcessingMode].self, from: fileURL).map(migrate)
    }

    /// 运行时兼容边界：缺失使用默认模式；损坏只在内存降级，绝不自动写盘。
    func load() -> [ProcessingMode] {
        switch loadResult() {
        case .value(let modes):
            return modes
        case .missing, .corrupt:
            return ProcessingMode.defaults
        }
    }

    private func migrate(_ saved: [ProcessingMode]) -> [ProcessingMode] {
        guard !saved.isEmpty else { return ProcessingMode.defaults }

        // Migrate legacy built-in flags for default modes, and drop unknown built-ins.
        var result = saved.compactMap { mode -> ProcessingMode? in
            if mode.id == ProcessingMode.directId {
                var direct = ProcessingMode.direct
                direct.name = mode.name
                direct.processingLabel = mode.processingLabel
                direct.hotkeyCode = mode.hotkeyCode
                direct.hotkeyModifiers = mode.hotkeyModifiers
                direct.hotkeyStyle = mode.hotkeyStyle
                return direct
            }
            if mode.id == ProcessingMode.smartDirectId {
                return migrateDefaultMode(mode, fallback: .smartDirect)
            }
            if mode.id == ProcessingMode.translateId {
                return migrateDefaultMode(mode, fallback: .translate)
            }
            if mode.id == ProcessingMode.formalWriting.id {
                return migrateSeededDefaultPrompt(
                    mode,
                    legacyPrompts: [ProcessingMode.legacyFormalWritingPromptTemplate],
                    fallbackPrompt: ProcessingMode.formalWriting.prompt
                )
            }
            if mode.id == ProcessingMode.translate.id {
                return migrateSeededDefaultPrompt(
                    mode,
                    legacyPrompts: [ProcessingMode.legacyTranslatePromptTemplate],
                    fallbackPrompt: ProcessingMode.translate.prompt
                )
            }
            // Drop legacy dual-channel mode (replaced by global "enhanced ASR" toggle)
            if mode.id == UUID(uuidString: "00000000-0000-0000-0000-000000000007")! {
                return nil
            }
            if mode.isBuiltin {
                return nil
            }
            return mode
        }

        // Ensure required built-in modes always exist.
        let resultIds = Set(result.map(\.id))
        for builtin in ProcessingMode.builtins where !resultIds.contains(builtin.id) {
            if let idx = ProcessingMode.builtins.firstIndex(where: { $0.id == builtin.id }) {
                let insertAt = min(idx, result.count)
                result.insert(builtin, at: insertAt)
            } else {
                result.append(builtin)
            }
        }

        // 名称/Prompt 仍是默认值的模式，跟随当前界面语言（自定义内容不动）
        return result.map(applyLanguageDefaults)
    }

    private func migrateDefaultMode(_ mode: ProcessingMode, fallback: ProcessingMode) -> ProcessingMode {
        guard mode.isBuiltin || mode.prompt.isEmpty else { return mode }

        var migrated = fallback
        if !mode.name.isEmpty {
            migrated.name = mode.name
        }
        if !mode.processingLabel.isEmpty {
            migrated.processingLabel = mode.processingLabel
        }
        migrated.hotkeyCode = mode.hotkeyCode
        migrated.hotkeyModifiers = mode.hotkeyModifiers
        migrated.hotkeyStyle = mode.hotkeyStyle
        migrated.isBuiltin = false
        return migrated
    }

    private func migrateSeededDefaultPrompt(
        _ mode: ProcessingMode,
        legacyPrompts: Set<String>,
        fallbackPrompt: String
    ) -> ProcessingMode {
        guard legacyPrompts.contains(mode.prompt) else { return mode }

        var migrated = mode
        migrated.prompt = fallbackPrompt
        migrated.isBuiltin = false
        return migrated
    }

    // MARK: - 语言感知的默认值迁移（2026-06-12 用户拍板：英文界面下默认模式全英文）

    /// 各默认模式的「已知默认名」集合：名称命中任一语言的默认名 → 视为未自定义，
    /// 重置为当前语言默认名；用户改过的名称（不在集合内）一律保留。
    /// 「Promp优化」是历史 typo 世代的默认名，必须入册否则存量数据不迁移。
    private static let knownDefaultNames: [UUID: Set<String>] = [
        ProcessingMode.direct.id: ["直出模式", "Direct Output"],
        ProcessingMode.smartDirect.id: ["智能模式", "Smart Mode"],
        ProcessingMode.formalWriting.id: ["语音润色", "Voice Polish"],
        ProcessingMode.promptOptimize.id: ["Prompt优化", "Promp优化", "Prompt Optimizer"],
        ProcessingMode.translate.id: ["英文翻译", "Translation"],
        ProcessingMode.commandMode.id: ["命令模式", "Command Mode"],
    ]

    /// 各默认模式的「已知默认处理标签」集合：同名称逻辑，自定义标签保留
    private static let knownDefaultLabels: [UUID: Set<String>] = [
        ProcessingMode.formalWriting.id: ["润色中", "Polishing"],
        ProcessingMode.promptOptimize.id: ["优化中", "Optimizing"],
        ProcessingMode.translate.id: ["翻译中", "Translating"],
        ProcessingMode.commandMode.id: ["执行中", "Executing"],
    ]

    /// 各默认模式的「已知默认 Prompt」集合（中英现行版 + legacy 世代）。
    /// Prompt 命中 → 重置为当前语言现行模板；自定义 Prompt 一律保留。
    private static let knownDefaultPrompts: [UUID: Set<String>] = [
        ProcessingMode.smartDirect.id: [
            ProcessingMode.smartDirectPromptTemplateZH,
            ProcessingMode.smartDirectPromptTemplateEN,
        ],
        ProcessingMode.formalWriting.id: [
            ProcessingMode.legacyFormalWritingPromptTemplate,
            ProcessingMode.legacyVoiceDraftEnginePromptTemplate,
            ProcessingMode.formalWritingPromptTemplateZH,
            ProcessingMode.formalWritingPromptTemplateEN,
        ],
        ProcessingMode.promptOptimize.id: [
            ProcessingMode.promptOptimizePromptTemplateZH,
            ProcessingMode.promptOptimizePromptTemplateEN,
        ],
        ProcessingMode.translate.id: [
            ProcessingMode.legacyTranslatePromptTemplate,
            ProcessingMode.translatePromptTemplateZH,
            ProcessingMode.translatePromptTemplateEN,
        ],
        ProcessingMode.commandMode.id: [
            ProcessingMode.commandModePromptTemplateZH,
            ProcessingMode.commandModePromptTemplateEN,
        ],
    ]

    /// 当前语言下的默认模式定义（取 name 与 prompt 用）
    private static func currentDefault(for id: UUID) -> ProcessingMode? {
        ProcessingMode.defaults.first { $0.id == id } ?? (id == ProcessingMode.smartDirect.id ? ProcessingMode.smartDirect : nil)
    }

    /// 名称/Prompt 命中已知默认值则切换到当前语言版本
    func applyLanguageDefaults(_ mode: ProcessingMode) -> ProcessingMode {
        guard let current = Self.currentDefault(for: mode.id) else { return mode }

        var migrated = mode
        if let names = Self.knownDefaultNames[mode.id], names.contains(mode.name) {
            migrated.name = current.name
        }
        if let labels = Self.knownDefaultLabels[mode.id], labels.contains(mode.processingLabel) {
            migrated.processingLabel = current.processingLabel
        }
        if let prompts = Self.knownDefaultPrompts[mode.id], prompts.contains(mode.prompt) {
            migrated.prompt = current.prompt
        }
        return migrated
    }
}
