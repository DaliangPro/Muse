import Foundation

// MARK: - Processing Mode
// 2026-07-09 J14：从 AppState.swift 迁出——领域模型不属于 UI 层。
// Prompt 模板见 ProcessingMode+Prompts.swift，LLM 结果清洗见 ProcessingMode+LLMCleanup.swift。

struct ProcessingMode: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var isBuiltin: Bool
    var processingLabel: String
    var hotkeyCode: Int?
    var hotkeyModifiers: UInt64?
    var hotkeyStyle: HotkeyStyle

    enum HotkeyStyle: String, Codable, CaseIterable {
        case hold    // press and hold to record
        case toggle  // press once to start, again to stop
    }

    /// Global default hotkey style, stored in UserDefaults.
    /// All new modes and built-in fallbacks read from here.
    static var defaultHotkeyStyle: HotkeyStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.defaultHotkeyStyle),
                  let style = HotkeyStyle(rawValue: raw)
            else { return .toggle }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKeys.defaultHotkeyStyle)
        }
    }

    init(
        id: UUID,
        name: String,
        prompt: String,
        isBuiltin: Bool,
        processingLabel: String = L("处理中", "Processing"),
        hotkeyCode: Int? = nil,
        hotkeyModifiers: UInt64? = nil,
        hotkeyStyle: HotkeyStyle? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltin = isBuiltin
        self.processingLabel = processingLabel
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeyStyle = hotkeyStyle ?? Self.defaultHotkeyStyle
    }

    static func newCustomMode(id: UUID = UUID(), name: String = L("新模式", "New Mode")) -> ProcessingMode {
        ProcessingMode(
            id: id,
            name: name,
            prompt: "",
            isBuiltin: false
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, isBuiltin, processingLabel
        case hotkeyCode, hotkeyModifiers, hotkeyStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        isBuiltin = try container.decode(Bool.self, forKey: .isBuiltin)
        processingLabel = try container.decodeIfPresent(String.self, forKey: .processingLabel) ?? L("处理中", "Processing")
        hotkeyCode = try container.decodeIfPresent(Int.self, forKey: .hotkeyCode)
        hotkeyModifiers = try container.decodeIfPresent(UInt64.self, forKey: .hotkeyModifiers)
        hotkeyStyle = try container.decodeIfPresent(HotkeyStyle.self, forKey: .hotkeyStyle) ?? Self.defaultHotkeyStyle
    }

    // MARK: - Built-in Mode IDs (stable, never change)
    static let directId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let smartDirectId = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    static let translateId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static var direct: ProcessingMode {
        ProcessingMode(
            id: directId,
            name: L("直出模式", "Direct Output"), prompt: "", isBuiltin: true,
            // 默认触发键（2026-07-06 大梁老师）：右 Option 单击开始、再单击结束（toggle）
            hotkeyCode: 61, hotkeyModifiers: 0, hotkeyStyle: .toggle
        )
    }

    static var smartDirect: ProcessingMode {
        ProcessingMode(
            id: smartDirectId,
            name: L("智能模式", "Smart Mode"), prompt: smartDirectPromptTemplate, isBuiltin: false
        )
    }

    var isFormalWritingMode: Bool {
        id == Self.formalWritingId
            || name.localizedCaseInsensitiveContains("润色")
            || name.localizedCaseInsensitiveContains("polish")
    }
    var isPromptOptimizeMode: Bool {
        id == Self.promptOptimizeId
            || name.localizedCaseInsensitiveContains("prompt")
    }
    var isTranslateMode: Bool {
        id == Self.translateId
            || id == Self.defaultTranslateId
            || name.localizedCaseInsensitiveContains("翻译")
            || name.localizedCaseInsensitiveContains("translat")
    }

    // MARK: - Default Custom Mode IDs (stable, for fresh installs)
    private static let formalWritingId = UUID(uuidString: "7FC0076F-A85E-454B-8789-47A2F15A6E2F")!
    private static let promptOptimizeId = UUID(uuidString: "5D0A24D4-ECE9-4C13-9FC5-F9C81BD6B1C3")!
    private static let defaultTranslateId = UUID(uuidString: "87AF4048-83C3-4306-8AF8-1E52DB7CA2F5")!
    private static let commandModeId = UUID(uuidString: "A3B1D9E7-6F42-4C8A-B5E0-9D3F7A2C1E84")!

    static var formalWriting: ProcessingMode {
        ProcessingMode(
            id: formalWritingId,
            name: L("语音润色", "Voice Polish"),
            prompt: formalWritingPromptTemplate,
            isBuiltin: false,
            processingLabel: L("润色中", "Polishing"),
            hotkeyCode: 18, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    static var promptOptimize: ProcessingMode {
        ProcessingMode(
            id: promptOptimizeId,
            name: L("Prompt优化", "Prompt Optimizer"),
            prompt: promptOptimizePromptTemplate,
            isBuiltin: false,
            processingLabel: L("优化中", "Optimizing"),
            hotkeyCode: 19, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    static var translate: ProcessingMode {
        ProcessingMode(
            id: defaultTranslateId,
            name: L("英文翻译", "Translation"),
            prompt: translatePromptTemplate,
            isBuiltin: false,
            processingLabel: L("翻译中", "Translating"),
            hotkeyCode: 20, hotkeyModifiers: 524288, hotkeyStyle: .toggle
        )
    }

    static var commandMode: ProcessingMode {
        ProcessingMode(
            id: commandModeId,
            name: L("命令模式", "Command Mode"),
            prompt: commandModePromptTemplate,
            isBuiltin: false,
            processingLabel: L("执行中", "Executing"),
            hotkeyStyle: .toggle
        )
    }

    static var builtins: [ProcessingMode] { [.direct] }
    static var defaults: [ProcessingMode] { [.direct, .formalWriting, .promptOptimize, .translate, .commandMode] }
}
