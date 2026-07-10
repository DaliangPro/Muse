import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Hotword storage with two independent stores:
/// - **Built-in file** (`builtin-hotwords.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`hotwords.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime (deduplicated, case-insensitive).
enum HotwordStorage {

    // MARK: - File paths

    private static var appSupportDir: URL { AppPaths.supportDir }

    /// Built-in hotwords file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-hotwords.json") }

    /// User hotwords file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("hotwords.json") }

    // MARK: - Default hotwords (used for initial seeding)

    /// Common tech terms that ASR engines frequently mis-transcribe.
    /// 默认内置热词（2026-06-13 大梁老师精简定稿）：从原 ~150 删减到 52 个高频常用词,
    /// 作为项目默认、打包分发给他人时的初始内置热词。
    static let defaultHotwords: [String] = [
        // ── AI models & companies ──
        "Claude", "Claude Code", "GPT", "Gemini", "Anthropic", "OpenAI",
        "DeepSeek", "Qwen", "Perplexity", "Midjourney", "Stable Diffusion",
        "Hugging Face", "xAI", "Grok", "Groq", "Copilot", "ChatGPT",

        // ── AI coding tools ──
        "Cursor", "Codex", "vibe coding", "MCP",

        // ── AI frameworks & infra ──
        "LangChain", "Dify", "Coze", "Ollama", "ComfyUI", "OpenRouter",

        // ── AI concepts ──
        "LLM", "RAG", "LoRA", "agentic", "TTS", "ASR",

        // ── Dev tools ──
        "GitHub", "VS Code", "Docker", "npm", "pip",

        // ── Programming terms ──
        "API", "SDK", "token", "prompt", "webhook", "OAuth", "JSON", "DMG",

        // ── Frameworks & languages ──
        "Next.js", "SwiftUI",

        // ── Hardware ──
        "NVIDIA", "CUDA", "GPU", "TPU",
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_hotwords_migrated_to_file_v2"
    private static let oldUDKey = "tf_hotwords"

    /// Syncs built-in file with code defaults and migrates old UserDefaults data.
    static func migrateIfNeeded() {
        // Always sync built-in file with code defaults (picks up new entries on app update)
        do {
            try saveBuiltin(defaultHotwords)
        } catch {
            AppLogger.log("[HotwordStorage] 内置热词同步失败: \(error.localizedDescription)")
        }

        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        let raw = UserDefaults.standard.string(forKey: oldUDKey) ?? ""
        let oldWords = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Filter out entries that duplicate built-in
        let builtinSet = Set(defaultHotwords.map { $0.lowercased() })
        let userOnly = oldWords.filter { !builtinSet.contains($0.lowercased()) }

        if !userOnly.isEmpty {
            do {
                try save(userOnly)
            } catch {
                AppLogger.log("[HotwordStorage] 旧热词迁移失败: \(error.localizedDescription)")
                return
            }
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - User file (Settings UI)

    static func load() -> [String] {
        return readFile(userFileURL)
    }

    static func save(_ words: [String]) throws {
        try writeFile(words, to: userFileURL)
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [String] {
        return readFile(builtinFileURL)
    }

    static func saveBuiltin(_ words: [String]) throws {
        try writeFile(words, to: builtinFileURL)
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in hotwords file in Finder.
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            try? saveBuiltin(defaultHotwords)
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - Effective (merge both stores)

    /// Returns user + built-in hotwords merged (deduplicated, case-insensitive).
    static func loadEffective() -> [String] {
        let builtin = loadBuiltin()
        let user = load()
        var seen = Set<String>()
        var result: [String] = []

        // 用户新增热词优先，避免被大批内置通用词稀释。
        for word in user {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                result.append(word)
            }
        }

        for word in builtin {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                result.append(word)
            }
        }

        return result
    }

    /// 下发 ASR 的热词总数上限（2026-06-13 用户拍板）：防一大批内置通用词稀释、
    /// 或超出火山引擎内联热词的数量限制。用户词全保留并排前,内置词补到上限内。
    static let asrHotwordLimit = 100

    /// 给 ASR 用的有效热词：用户词优先排前，内置词补到上限。
    /// 返回的 userCount 标出前多少个是用户词。
    static func loadEffectiveForASR(limit: Int = asrHotwordLimit) -> (words: [String], userCount: Int) {
        var seen = Set<String>()
        var userWords: [String] = []
        for word in load() {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                userWords.append(word)
            }
        }
        var builtinWords: [String] = []
        for word in loadBuiltin() {
            let lower = word.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                builtinWords.append(word)
            }
        }
        // 用户词全保留;内置词只补到上限内,优先保住用户词
        let remaining = max(limit - userWords.count, 0)
        let words = userWords + Array(builtinWords.prefix(remaining))
        return (words: words, userCount: userWords.count)
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [String] {
        JSONFileStore.read([String].self, from: url) ?? []
    }

    private static func writeFile(_ words: [String], to url: URL) throws {
        try JSONFileStore.writeOrThrow(words, to: url)
    }
}
