import Foundation

// MARK: - LLM 输入守卫与结果清洗（2026-07-09 J14 自 AppState.swift 迁出）

extension ProcessingMode {
    func applyingLLMFormatGuard(to expandedPrompt: String) -> String {
        guard !expandedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return expandedPrompt
        }

        // contains 检查须覆盖中英双版本：用户存量 prompt 可能内嵌另一语言的守卫
        var guardedPrompt = expandedPrompt
        let hasListGuard = guardedPrompt.contains(Self.formalWritingListGuardZH)
            || guardedPrompt.contains(Self.formalWritingListGuardEN)
        if isFormalWritingMode && !hasListGuard {
            guardedPrompt = """
            \(guardedPrompt)

            \(Self.formalWritingListGuard)

            \(Self.formalWritingCleanupGuard)
            """
        }

        let hasBoundaryGuard = guardedPrompt.contains(Self.llmOutputBoundaryGuardZH)
            || guardedPrompt.contains(Self.llmOutputBoundaryGuardEN)
        if !hasBoundaryGuard {
            guardedPrompt = """
            \(guardedPrompt)

            \(Self.llmOutputBoundaryGuard)
            """
        }
        return guardedPrompt
    }

    func applyingLLMResultCleanup(to result: String) -> String {
        var cleaned = Self.stripCommonLLMResponsePrefix(result.strippingThinkTags())
        if !isPromptOptimizeMode {
            cleaned = Self.stripLikelyPromptLeakage(from: cleaned)
        }

        guard isFormalWritingMode else {
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let replacements: [(String, String)] = [
            ("CodeX", "Codex"),
            ("Cloud Code", "Claude Code"),
            ("markdown", "Markdown"),
            ("本质上就是", "本质上是"),
            ("其实就是", "本质上是"),
            ("其实它就是", "本质上是"),
            ("也就是", "换句话说"),
            ("就是说", "换句话说"),
            ("就是一个", "是一个"),
            ("就是一种", "是一种"),
            ("就是要", "要"),
            ("就是我", "我"),
            ("，就是", "，"),
            ("。就是", "。"),
        ]
        for (source, target) in replacements {
            cleaned = cleaned.replacingOccurrences(of: source, with: target)
        }
        cleaned = cleaned.replacingOccurrences(of: "就是", with: "是")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applyingFinalInsertionCleanup(to result: String) -> String {
        var cleaned = result.strippingThinkTags()
        if !isPromptOptimizeMode {
            cleaned = Self.stripLikelyPromptLeakage(from: cleaned)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCommonLLMResponsePrefix(_ result: String) -> String {
        result
            .replacingOccurrences(
                of: #"^\s*(最终文本|输出结果|结果|润色后|改写后|翻译结果|处理结果)[：:]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLikelyPromptLeakage(from result: String) -> String {
        var cleaned = result
        let inlineMarkers = [
            "以下是语音识别的原始输出",
            "以下是原始内容",
            "以下是用户原始输入",
            "请在以下规则下执行命令",
            "现在选择的内容是",
            "现在剪切板",
            "命令如下：",
            "命令如下:",
            "系统指令：",
            "系统指令:",
            "开发者指令：",
            "开发者指令:",
            "要求后续变更",
            "Type / for commands",
            "Message Codex",
            "Message ChatGPT",
            "Ask anything",
            "输入 / 使用命令",
            "输入消息"
        ]

        for marker in inlineMarkers {
            guard let range = cleaned.range(of: marker) else { continue }
            let prefix = String(cleaned[..<range.lowerBound])
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                cleaned = prefix
                break
            }
        }

        let lines = cleaned.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines {
            if !kept.isEmpty,
               kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
               isLikelyPromptLeakLine(line) {
                break
            }
            kept.append(line)
        }

        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyPromptLeakLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let markers = [
            "#Role", "# Role", "#角色", "# 角色",
            "#核心目标", "# 核心目标",
            "#核心规则", "# 核心规则",
            "#严格规则", "# 严格规则",
            "#示例", "# 示例",
            "#以下是", "# 以下是",
            "以下是语音识别", "以下是原始内容", "以下是用户原始输入",
            "请在以下规则下执行命令",
            "现在选择的内容是", "现在剪切板",
            "命令如下", "系统指令", "开发者指令",
            "要求后续变更",
            "用户输入：", "用户输入:",
            "原始输入：", "原始输入:",
            "提示词：", "提示词:",
            "Type / for commands",
            "Message Codex",
            "Message ChatGPT",
            "Ask anything",
            "输入 / 使用命令",
            "输入消息"
        ]
        return markers.contains { trimmed.hasPrefix($0) }
    }
}
