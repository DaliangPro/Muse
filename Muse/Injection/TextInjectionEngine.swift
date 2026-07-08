import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class TextInjectionEngine: @unchecked Sendable {

    private struct ClipboardSnapshot {
        private static let maxSnapshotBytes = 32 * 1024 * 1024

        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }

        let items: [Item]
        let changeCount: Int
        let canRestore: Bool

        static func capture() -> ClipboardSnapshot {
            let pasteboard = NSPasteboard.general
            let changeCount = pasteboard.changeCount
            var items: [Item] = []
            var totalBytes = 0

            for pasteboardItem in pasteboard.pasteboardItems ?? [] {
                let types = pasteboardItem.types
                guard !types.isEmpty else { continue }

                var data: [NSPasteboard.PasteboardType: Data] = [:]
                for type in types {
                    guard let itemData = pasteboardItem.data(forType: type) else {
                        return ClipboardSnapshot(items: [], changeCount: changeCount, canRestore: false)
                    }
                    totalBytes += itemData.count
                    guard totalBytes <= maxSnapshotBytes else {
                        return ClipboardSnapshot(items: [], changeCount: changeCount, canRestore: false)
                    }
                    data[type] = itemData
                }
                items.append(Item(types: types, data: data))
            }

            return ClipboardSnapshot(items: items, changeCount: changeCount, canRestore: true)
        }

        func restore(expectedChangeCount: Int) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expectedChangeCount else { return }
            guard canRestore else { return }

            // 原剪贴板为空时 items 为空——此时仍需 clearContents 清掉刚写入的
            // 识别文本、恢复成「空」的原状；不能因 items 空就直接 return，否则识别文本残留（关了自动复制也留）。
            // 2026-06-24 大梁老师报的 bug：录音前剪贴板是图片/空 → 识别结果偷偷留进剪贴板
            pasteboard.clearContents()
            var restoredItems: [NSPasteboardItem] = []
            for item in items {
                let pasteboardItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data[type] {
                        pasteboardItem.setData(data, forType: type)
                    }
                }
                restoredItems.append(pasteboardItem)
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    // MARK: - Public

    var preserveClipboard = true

    static var canReadFocusedEditableElement: Bool {
        AXIsProcessTrusted()
    }

    static func frontmostApplicationHasFocusedEditableElement() -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return false }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        guard let focusedElement = elementAttribute(applicationElement, kAXFocusedUIElementAttribute as CFString) else {
            return false
        }
        return isEditableElement(focusedElement, depth: 0)
    }

    /// 自绘渲染、AX 树不暴露焦点元素的应用（微信 4.x/QQ/钉钉/企业微信等腾讯系与 IM 类）：
    /// 焦点检测必然失败，但用户主动呼出语音输入时几乎必然停在输入框——
    /// 对这些 app 跳过检测直接注入，否则永远无法上屏（2026-07 修微信不注入）
    private static let axOpaqueBundleIDs: Set<String> = [
        "com.tencent.qq",
        "com.tencent.WeWorkMac",
        "com.alibaba.DingTalkMac",
    ]

    static func isAXOpaqueApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // 微信(含双开改包)统一前缀匹配
        if bundleID.hasPrefix("com.tencent.xinWeChat") { return true }
        return axOpaqueBundleIDs.contains(bundleID)
    }

    /// 同步注入文本。内部含合计 ~200ms 的 usleep 节拍（REPAIR_PLAN B6），
    /// **禁止从主线程调用**——现实调用方是 RecognitionSession（actor，
    /// 运行于协作线程池），若未来新增调用方必须保持非主线程语境。
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        // REPAIR_PLAN B1：未授权辅助功能时，模拟 Cmd+V 会被系统静默丢弃，
        // 若继续走常规路径，随后的剪贴板恢复会把刚写入的文本一并抹掉，
        // 用户文本两头落空。此时改为：文本留在剪贴板、明确告知手动粘贴。
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return .copiedToClipboardPermissionMissing
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if Self.isAXOpaqueApp(frontmostBundleID) {
            DebugFileLogger.log("inject: axOpaqueApp bypass frontmost=\(frontmostBundleID ?? "unknown")")
            // 微信等重客户端处理 Cmd+V 慢，恢复剪贴板多等一拍防竞态
            return injectViaClipboard(text, generousRestoreDelay: true)
        }

        guard Self.frontmostApplicationHasFocusedEditableElement() else {
            DebugFileLogger.log("inject: noFocusedInput frontmost=\(frontmostBundleID ?? "unknown")")
            if !preserveClipboard {
                copyToClipboard(text)
                return .noFocusedInput(copiedToClipboard: true)
            }
            return .noFocusedInput(copiedToClipboard: false)
        }
        return injectViaClipboard(text)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Clipboard injection

    private func injectViaClipboard(_ text: String, generousRestoreDelay: Bool = false) -> InjectionOutcome {
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture() : nil
        let hasFrontmostApplication = NSWorkspace.shared.frontmostApplication != nil

        copyToClipboard(text)
        let postWriteChangeCount = NSPasteboard.general.changeCount

        usleep(50_000)
        simulatePaste()
        usleep(100_000)

        let outcome: InjectionOutcome = hasFrontmostApplication ? .inserted : .copiedToClipboard

        if outcome == .inserted, let savedClipboard {
            // 恢复延迟差异化（2026-07 修回归：全局 350ms 曾拖慢所有 app 的注入手感）——
            // 仅微信等已知慢客户端多等防「粘贴到恢复后的旧剪贴板」竞态；普通 app 保持原节奏
            usleep(generousRestoreDelay ? 300_000 : 50_000)
            savedClipboard.restore(expectedChangeCount: postWriteChangeCount)
        }

        return outcome
    }

    private func simulatePaste() {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Focus Detection

    private static func isEditableElement(_ element: AXUIElement, depth: Int) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)

        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return true
        }
        if subrole == "AXSearchField" {
            return true
        }
        if boolAttribute(element, "AXEditable" as CFString) == true {
            return true
        }
        // 注意：不要在这里加「AXWebArea 即输入框」「支持选区属性即输入框」这类宽松启发式——
        // 浏览器页面/PDF/只读文本视图都会命中，导致无输入框场景被误判、复制兜底界面永不出现
        // （2026-07-08 修：微信等自绘 app 的注入由 isAXOpaqueApp 直通名单负责，不靠此处放宽）
        guard depth < 3,
              let parent = elementAttribute(element, kAXParentAttribute as CFString)
        else { return false }
        return isEditableElement(parent, depth: depth + 1)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

}
