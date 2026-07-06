import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Snippet replacement with two independent stores:
/// - **Built-in file** (`builtin-snippets.json`): seeded from defaults, user-editable via Finder for bulk ops
/// - **User file** (`snippets.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime; user entries override built-in on trigger conflict.
enum SnippetStorage {
    static let draftTriggerPrefix = "__muse_draft__:"
    static let draftTriggerDisplayTitle = L("待补触发词", "Draft trigger")

    // MARK: - File paths

    private static var appSupportDir: URL { AppPaths.supportDir }

    /// Built-in snippets file (seeded from defaults, user-editable for bulk ops)
    static var builtinFileURL: URL { appSupportDir.appendingPathComponent("builtin-snippets.json") }

    /// User snippets file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("snippets.json") }

    // MARK: - Codable model

    private struct Entry: Codable {
        let trigger: String
        let replacement: String
    }

    // MARK: - Default snippets (used for initial seeding)

    /// Default ASR correction mappings. Seeded into builtin-snippets.json on first launch.
    /// Triggers are matched case-insensitively and space-insensitively via `buildFlexPattern`.
    ///
    /// Verified against: Volcengine Seed ASR 2.0, Qwen3-ASR 0.6B/1.7B, SenseVoice-Small.
    static let defaultSnippets: [(trigger: String, value: String)] = [

        // ── vibe coding (ASR 几乎必错) ──
        ("web coding",      "vibe coding"),
        ("webb coding",     "vibe coding"),
        ("vab coding",      "vibe coding"),
        ("vabe coding",     "vibe coding"),
        ("vibes coding",    "vibe coding"),
        ("Vipcoding",       "vibe coding"),
        ("vipe coding",     "vibe coding"),
        ("vb coding",       "vibe coding"),
        ("vib coding",      "vibe coding"),
        ("va coding",       "vibe coding"),
        ("vivcoding",       "vibe coding"),
        ("wife coding",     "vibe coding"),

        // ── Claude ──
        ("Cloud Code",      "Claude Code"),
        ("clod",            "Claude"),
        ("clawed",          "Claude"),
        ("claud",           "Claude"),

        // ── Anthropic ──
        ("Asthropic",       "Anthropic"),
        ("Anthropropic",    "Anthropic"),
        ("Anthropick",      "Anthropic"),
        ("Anthrobic",       "Anthropic"),
        ("and tropic",      "Anthropic"),
        ("an tropic",       "Anthropic"),
        ("anthrophic",      "Anthropic"),

        // ── ChatGPT ──
        ("chat GPT",        "ChatGPT"),

        // ── DeepSeek ──
        ("deepse",          "DeepSeek"),
        ("deep sick",       "DeepSeek"),
        ("deep seek",       "DeepSeek"),
        ("deep sec",        "DeepSeek"),

        // ── Gemini ──
        ("jiminy",          "Gemini"),
        ("gem any",         "Gemini"),

        // ── Qwen ──
        ("Queen三",         "Qwen3"),
        ("Queen 三",        "Qwen3"),
        ("Queen3",          "Qwen3"),
        ("Queen 3",         "Qwen3"),
        ("qun三",           "Qwen3"),
        ("Qu3",             "Qwen3"),
        ("Queen三点五",     "Qwen3.5"),
        ("Queen 3.5",       "Qwen3.5"),
        ("quin三点五",      "Qwen3.5"),
        ("qun三点五",       "Qwen3.5"),
        ("quin三点",        "Qwen3"),

        // ── Grok ──
        ("grock",           "Grok"),

        // ── Llama / Ollama ──
        ("ELMA",            "Llama"),
        ("OELMA",           "Ollama"),

        // ── Midjourney / Copilot / Perplexity ──
        ("mid journey",     "Midjourney"),
        ("co pilot",        "Copilot"),
        ("perplex city",    "Perplexity"),

        // ── Hugging Face ──
        ("hugging phase",   "Hugging Face"),
        ("hug and face",    "Hugging Face"),

        // ── Codex ──
        ("codecs",          "Codex"),
        ("CodeX",           "Codex"),
        ("Codec",           "Codex"),

        // ── JSON ──
        ("Jason",           "JSON"),

        // ── fine-tuning ──
        ("finight tuning",  "fine-tuning"),
        ("find tuning",     "fine-tuning"),
        ("fine tuning",     "fine-tuning"),
        ("fine tune",       "fine-tune"),

        // ── LoRA / QLoRA ──
        ("lore a",          "LoRA"),
        ("lor a",           "LoRA"),
        ("Q lore a",        "QLoRA"),

        // ── agentic ──
        ("a genetic",       "agentic"),
        ("a gentic",        "agentic"),

        // ── multimodal / multi-agent ──
        ("multi modal",     "multimodal"),
        ("multi agent",     "multi-agent"),
        ("multiag",         "multi-agent"),

        // ── few-shot / zero-shot / in-context learning ──
        ("few shot",        "few-shot"),
        ("zero shot",       "zero-shot"),
        ("in context learning", "in-context learning"),

        // ── embedding / context window ──
        ("imbedding",       "embedding"),
        ("contexwin",       "context window"),
        ("context win",     "context window"),

        // ── LangChain / LlamaIndex ──
        ("long chain",      "LangChain"),
        ("long train",      "LangChain"),
        ("llama index",     "LlamaIndex"),
        ("lama index",      "LlamaIndex"),

        // ── AI frameworks (CrewAI, AutoGen, ComfyUI, ControlNet) ──
        ("crew AI",         "CrewAI"),
        ("auto gen",        "AutoGen"),
        ("auto Jen",        "AutoGen"),
        ("comfy UI",        "ComfyUI"),
        ("control net",     "ControlNet"),

        // ── AI coding tools ──
        ("wind surf",       "Windsurf"),
        ("Klein",           "Cline"),
        ("C line",          "Cline"),
        ("aid her",         "Aider"),
        ("open router",     "OpenRouter"),
        ("light LLM",       "LiteLLM"),
        ("lite LLM",        "LiteLLM"),
        ("VLLM",            "vLLM"),
        ("llama CPP",       "llama.cpp"),
        ("curser",          "Cursor"),
        ("克色",            "Cursor"),

        // ── Dev tools ──
        ("get hub",         "GitHub"),
        ("git hub",         "GitHub"),
        ("VS code",         "VS Code"),
        ("Kubanetes",       "Kubernetes"),
        ("Kubenetes",       "Kubernetes"),
        ("Nextjs",          "Next.js"),
        ("type script",     "TypeScript"),
        ("typepescript",    "TypeScript"),
        ("graph QL",        "GraphQL"),
        ("web socket",      "WebSocket"),
        ("pinecom",         "Pinecone"),

        // ── Infra & formats ──
        ("DM g",            "DMG"),
        ("verse cell",      "Vercel"),
        ("verse L",         "Vercel"),
        ("super base",      "Supabase"),
        ("cloud flare",     "Cloudflare"),
        ("cloud flair",     "Cloudflare"),
        ("N video",         "NVIDIA"),
        ("onyx",            "ONNX"),
    ]

    // MARK: - Initialization

    private static let migratedKey = "tf_snippets_migrated_to_file_v2"
    private static let oldUDKey = "tf_snippets"

    /// Syncs built-in file with code defaults and migrates old UserDefaults data.
    static func migrateIfNeeded() {
        // Always sync built-in file with code defaults (picks up new entries on app update)
        do {
            try saveBuiltin(defaultSnippets)
        } catch {
            AppLogger.log("[SnippetStorage] 内置替换规则同步失败: \(error.localizedDescription)")
        }

        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: oldUDKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }

        let oldSnippets = pairs.compactMap { pair -> (trigger: String, value: String)? in
            guard pair.count == 2 else { return nil }
            return (trigger: pair[0], value: pair[1])
        }

        // Filter out entries that duplicate built-in
        func norm(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }
        let builtinKeys = Set(defaultSnippets.map { "\(norm($0.trigger))\t\($0.value)" })
        let userOnly = oldSnippets.filter { !builtinKeys.contains("\(norm($0.trigger))\t\($0.value)") }

        if !userOnly.isEmpty {
            do {
                try save(userOnly)
            } catch {
                AppLogger.log("[SnippetStorage] 旧替换规则迁移失败: \(error.localizedDescription)")
                return
            }
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - User file (Settings UI)

    static func load() -> [(trigger: String, value: String)] {
        return readFile(userFileURL)
    }

    static func save(_ snippets: [(trigger: String, value: String)]) throws {
        try writeFile(snippets, to: userFileURL)
        invalidateCache()
    }

    // MARK: - Built-in file (Finder editable)

    static func loadBuiltin() -> [(trigger: String, value: String)] {
        return readFile(builtinFileURL)
    }

    static func saveBuiltin(_ snippets: [(trigger: String, value: String)]) throws {
        try writeFile(snippets, to: builtinFileURL)
        invalidateCache()
    }

    static func builtinCount() -> Int {
        return loadBuiltin().count
    }

    /// Reveal built-in snippets file in Finder.
    static func revealBuiltinInFinder() {
        if !FileManager.default.fileExists(atPath: builtinFileURL.path) {
            try? saveBuiltin(defaultSnippets)
        }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([builtinFileURL])
        #endif
    }

    // MARK: - Compiled cache

    private struct CompiledRule {
        let regex: NSRegularExpression
        let template: String  // pre-escaped replacement
    }

    /// Cached compiled rules. Rebuilt only when snippets change.
    private static var cachedRules: [CompiledRule]?

    /// Call after saving either file to force recompilation on next apply.
    static func invalidateCache() {
        cachedRules = nil
    }

    static func isDraftTrigger(_ trigger: String) -> Bool {
        trigger.hasPrefix(draftTriggerPrefix)
    }

    static func displayTrigger(_ trigger: String) -> String {
        isDraftTrigger(trigger) ? draftTriggerDisplayTitle : trigger
    }

    private static func compiledRules() -> [CompiledRule] {
        if let cached = cachedRules { return cached }
        let builtinSnippets = loadBuiltin()
        let userSnippets = load()
        let userTriggers = Set(userSnippets.map { $0.trigger.lowercased() })
        let effectiveBuiltin = builtinSnippets.filter { !userTriggers.contains($0.trigger.lowercased()) }
        let allSnippets = effectiveBuiltin + userSnippets

        let rules = allSnippets.compactMap { snippet -> CompiledRule? in
            guard !isDraftTrigger(snippet.trigger) else { return nil }
            let pattern = buildFlexPattern(snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return CompiledRule(regex: regex, template: NSRegularExpression.escapedTemplate(for: snippet.value))
        }
        cachedRules = rules
        return rules
    }

    // MARK: - Apply (merge both stores)

    /// Apply built-in + user snippets. User entries override built-in on trigger conflict.
    static func applyEffective(to text: String) -> String {
        var result = text
        for rule in compiledRules() {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    // MARK: - Pattern building

    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    /// Uses ASCII-only word boundaries (not `\b`) so CJK/Latin boundaries work correctly.
    private static func buildFlexPattern(_ trigger: String) -> String {
        let chars = trigger.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
        let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        return "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [(trigger: String, value: String)] {
        let entries = JSONFileStore.read([Entry].self, from: url) ?? []
        return entries.map { (trigger: $0.trigger, value: $0.replacement) }
    }

    private static func writeFile(_ snippets: [(trigger: String, value: String)], to url: URL) throws {
        let entries = snippets.map { Entry(trigger: $0.trigger, replacement: $0.value) }
        try JSONFileStore.writeOrThrow(entries, to: url)
    }
}
