import XCTest
@testable import Muse

final class PersonalLexiconTests: XCTestCase {
    func testStorageRoundTripExportAndAtomicClear() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let document = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Claude Code",
                aliases: ["Cloud Code", "Cloud Code"],
                source: .manual
            )]
        )

        try PersonalLexiconStorage.save(
            document,
            syncToASR: false,
            context: fixture.context
        )

        let loaded = PersonalLexiconStorage.load(context: fixture.context)
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].aliases, ["Cloud Code"])
        let exported = try PersonalLexiconStorage.exportData(context: fixture.context)
        XCTAssertEqual(
            try JSONDecoder().decode(PersonalLexiconDocument.self, from: exported),
            loaded
        )

        try PersonalLexiconStorage.clear(context: fixture.context)
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PersonalLexiconStorage.fileURL(in: fixture.context).path
        ))
    }

    func testSnippetCopyIsExplicitSelectiveAndNonDestructive() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let snippets = [
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "这是一整句错误规则。", value: "这是一整句正确文字。"),
            (trigger: SnippetStorage.draftTriggerPrefix + "1", value: "Draft"),
        ]
        try SnippetStorage.save(snippets, context: fixture.context)

        let copied = try PersonalLexiconStorage.copyEligibleSnippets(context: fixture.context)

        XCTAssertEqual(copied, 1)
        XCTAssertEqual(SnippetStorage.load(context: fixture.context).map(\.trigger), snippets.map(\.trigger))
        let entries = PersonalLexiconStorage.load(context: fixture.context).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].canonical, "Claude Code")
        XCTAssertEqual(entries[0].aliases, ["Cloud Code"])
    }

    func testConfirmedEntriesSynchronizeCanonicalAndAliasesToASRStores() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save([], context: fixture.context)
        try SnippetStorage.save([], context: fixture.context)
        let entry = PersonalLexiconEntry(
            canonical: "Kubernetes",
            aliases: ["Kubernetez"]
        )

        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(schemaVersion: 1, entries: [entry]),
            context: fixture.context
        )

        XCTAssertTrue(HotwordStorage.load(context: fixture.context).contains("Kubernetes"))
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Kubernetez" && $0.value == "Kubernetes"
        })
    }

    func testResolverUsesPriorityThresholdAndConflictMargin() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Claude Code",
                aliases: ["Cloud Code"]
            )]
        )
        let exact = EntityResolver.resolve(
            segments: [segment("请用 Cloud Code 修改。")],
            lexicon: lexicon,
            snippets: [(trigger: "Cloud Code", value: "Other Tool")],
            hotwords: [],
            context: WritingContext()
        )
        XCTAssertEqual(exact.first?.canonical, "Claude Code")
        XCTAssertEqual(exact.first?.candidateSource, .personalLexicon)
        XCTAssertEqual(
            EntityResolver.applying(exact, to: "请用 Cloud Code 修改。"),
            "请用 Claude Code 修改。"
        )

        let fuzzy = EntityResolver.resolve(
            segments: [segment("Kubernetez")],
            lexicon: .empty,
            snippets: [],
            hotwords: ["Kubernetes"],
            context: WritingContext()
        )
        XCTAssertEqual(fuzzy.first?.canonical, "Kubernetes")
        XCTAssertGreaterThanOrEqual(fuzzy.first?.confidence ?? 0, 0.88)

        let ambiguous = EntityResolver.resolve(
            segments: [segment("Kubernetez")],
            lexicon: .empty,
            snippets: [],
            hotwords: ["Kubernetes", "Kuberneter"],
            context: WritingContext()
        )
        XCTAssertTrue(ambiguous.isEmpty)
    }

    private func segment(_ text: String) -> RecognitionSegment {
        RecognitionSegment(
            id: "s1",
            text: text,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
    }
}

private final class StorageFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusePersonalLexiconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MusePersonalLexiconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
