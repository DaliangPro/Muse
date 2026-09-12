import Foundation

/// 正常输出使用已有直出/轻度处理器；只保存选择，不迁移或覆盖模式文件。
enum NormalOutputSettings {
    static let preferenceKey = "tf_normalOutputUsesLightPolish"

    static func usesLightPolish(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    static func isNormal(_ mode: ProcessingMode) -> Bool {
        mode.id == ProcessingMode.directId || mode.id == ProcessingMode.lightPolishId
    }

    static func resolve(_ mode: ProcessingMode, in modes: [ProcessingMode], light: Bool) -> ProcessingMode {
        guard isNormal(mode) else { return mode }
        let targetID = light ? ProcessingMode.lightPolishId : ProcessingMode.directId
        var result = modes.first { $0.id == targetID } ?? (light ? .lightPolish : .direct)
        result.name = L("正常输出", "Normal Output")
        let shortcut = modes.first { $0.id == ProcessingMode.directId } ?? .direct
        result.hotkeyCode = shortcut.hotkeyCode
        result.hotkeyModifiers = shortcut.hotkeyModifiers
        result.hotkeyStyle = shortcut.hotkeyStyle
        return result
    }

    static func visibleModes(in modes: [ProcessingMode], light: Bool) -> [ProcessingMode] {
        var insertedNormal = false
        return modes.compactMap { mode in
            guard isNormal(mode) else { return mode }
            guard !insertedNormal else { return nil }
            insertedNormal = true
            return resolve(mode, in: modes, light: light)
        }
    }
}
