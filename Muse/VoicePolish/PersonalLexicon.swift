import Foundation

enum PersonalLexiconEntrySource: String, Codable, Sendable, Equatable {
    case manual
    case snippetCopy
    case correctionCandidate
}

struct PersonalLexiconEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var canonical: String
    var aliases: [String]
    var source: PersonalLexiconEntrySource
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        canonical: String,
        aliases: [String],
        source: PersonalLexiconEntrySource = .manual,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.source = source
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

struct PersonalLexiconDocument: Codable, Sendable, Equatable {
    let schemaVersion: Int
    var entries: [PersonalLexiconEntry]

    static let empty = PersonalLexiconDocument(schemaVersion: 1, entries: [])
}

enum PersonalLexiconStorage {
    static func fileURL(in context: VocabularyStorageContext = .production) -> URL {
        context.supportDirectory.appendingPathComponent("voice-polish-lexicon.json")
    }

    static func loadResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<PersonalLexiconDocument> {
        JSONFileStore.read(
            PersonalLexiconDocument.self,
            from: fileURL(in: context),
            fileManager: context.fileManager
        )
    }

    static func load(context: VocabularyStorageContext = .production) -> PersonalLexiconDocument {
        switch loadResult(context: context) {
        case .value(let document):
            return normalized(document)
        case .missing, .corrupt:
            return .empty
        }
    }

    static func save(
        _ document: PersonalLexiconDocument,
        syncToASR: Bool = true,
        context: VocabularyStorageContext = .production
    ) throws {
        let cleaned = normalized(document)
        try JSONFileStore.writeOrThrow(cleaned, to: fileURL(in: context))
        if syncToASR {
            try syncConfirmedEntriesToASR(cleaned.entries, context: context)
        }
    }

    static func clear(context: VocabularyStorageContext = .production) throws {
        try save(.empty, syncToASR: false, context: context)
    }

    static func exportData(context: VocabularyStorageContext = .production) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(load(context: context))
    }

    /// 仅复制短实体映射；整句、换行、带句末标点或过长规则全部跳过。
    /// 原 snippets 文件只读不改，迁移由 UI 明确触发。
    @discardableResult
    static func copyEligibleSnippets(
        context: VocabularyStorageContext = .production
    ) throws -> Int {
        let snippets = SnippetStorage.load(context: context)
        var document = load(context: context)
        var count = 0
        for snippet in snippets where eligibleSnippet(snippet) {
            let canonical = snippet.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = document.entries.firstIndex(where: {
                normalizedKey($0.canonical) == normalizedKey(canonical)
            }) {
                if !document.entries[index].aliases.contains(where: {
                    normalizedKey($0) == normalizedKey(alias)
                }) {
                    document.entries[index].aliases.append(alias)
                    count += 1
                }
            } else {
                document.entries.append(PersonalLexiconEntry(
                    canonical: canonical,
                    aliases: [alias],
                    source: .snippetCopy
                ))
                count += 1
            }
        }
        try save(document, context: context)
        return count
    }

    private static func eligibleSnippet(_ snippet: (trigger: String, value: String)) -> Bool {
        let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = snippet.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !SnippetStorage.isDraftTrigger(trigger),
              (2...64).contains(trigger.count),
              (2...64).contains(value.count),
              !trigger.contains("\n"),
              !value.contains("\n") else { return false }
        let sentenceMarks = CharacterSet(charactersIn: "。！？；!?;。")
        return trigger.rangeOfCharacter(from: sentenceMarks) == nil
            && value.rangeOfCharacter(from: sentenceMarks) == nil
    }

    private static func normalized(_ document: PersonalLexiconDocument) -> PersonalLexiconDocument {
        var seenCanonicals = Set<String>()
        var entries: [PersonalLexiconEntry] = []
        for var entry in document.entries {
            entry.canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.canonical.isEmpty else { continue }
            let canonicalKey = normalizedKey(entry.canonical)
            guard seenCanonicals.insert(canonicalKey).inserted else { continue }
            var seenAliases = Set<String>()
            entry.aliases = entry.aliases.compactMap { alias in
                let cleaned = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalizedKey(cleaned)
                guard !cleaned.isEmpty,
                      key != canonicalKey,
                      seenAliases.insert(key).inserted else { return nil }
                return cleaned
            }
            entries.append(entry)
        }
        return PersonalLexiconDocument(schemaVersion: 1, entries: entries)
    }

    private static func syncConfirmedEntriesToASR(
        _ entries: [PersonalLexiconEntry],
        context: VocabularyStorageContext
    ) throws {
        let enabled = entries.filter(\.isEnabled)
        var hotwords = HotwordStorage.load(context: context)
        let hotwordKeys = Set(hotwords.map(normalizedKey))
        hotwords.append(contentsOf: enabled.map(\.canonical).filter {
            !hotwordKeys.contains(normalizedKey($0))
        })
        try HotwordStorage.save(hotwords, context: context)

        var snippets = SnippetStorage.load(context: context)
        let snippetKeys = Set(snippets.map { normalizedKey($0.trigger) })
        for entry in enabled {
            snippets.append(contentsOf: entry.aliases.filter {
                !snippetKeys.contains(normalizedKey($0))
            }.map { (trigger: $0, value: entry.canonical) })
        }
        try SnippetStorage.save(snippets, context: context)
    }

    private static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace }
    }
}
