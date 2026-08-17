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

    func testClearRemovesOnlyASRItemsOwnedByPersonalLexicon() throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        try HotwordStorage.save(["Existing"], context: fixture.context)
        try SnippetStorage.save(
            [(trigger: "Existing Alias", value: "Existing")],
            context: fixture.context
        )
        try PersonalLexiconStorage.save(
            PersonalLexiconDocument(
                schemaVersion: 1,
                entries: [
                    PersonalLexiconEntry(canonical: "Existing", aliases: ["Existing Alias"]),
                    PersonalLexiconEntry(canonical: "Kubernetes", aliases: ["Kubernetez"]),
                ]
            ),
            context: fixture.context
        )

        try PersonalLexiconStorage.clear(context: fixture.context)

        XCTAssertEqual(HotwordStorage.load(context: fixture.context), ["Existing"])
        let snippets = SnippetStorage.load(context: fixture.context)
        XCTAssertTrue(snippets.contains { $0.trigger == "Existing Alias" && $0.value == "Existing" })
        XCTAssertFalse(snippets.contains { $0.trigger == "Kubernetez" })
        XCTAssertTrue(PersonalLexiconStorage.load(context: fixture.context).entries.isEmpty)
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

    func testResolverMatchesKnownAliasAcrossCaseSpacesAndHyphensWithoutSubstringDamage() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "Typeless",
                aliases: ["Type less"]
            )]
        )
        let source = "Type less、type-less、typeless 都是术语，prototype-less 保持原样。"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains { $0.surfaceText == "Type less" })
        XCTAssertTrue(resolutions.contains { $0.surfaceText == "type-less" })
        XCTAssertTrue(resolutions.contains { $0.surfaceText == "typeless" })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "Typeless、Typeless、Typeless 都是术语，prototype-less 保持原样。"
        )
    }

    func testResolverOnlyAppliesKnownAliasAtEntityBoundaries() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(
                canonical: "CAT",
                aliases: ["Cat"]
            )]
        )
        let source = "Cat catalog concatenate"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "CAT catalog concatenate"
        )
    }

    func testResolverUsesEnglishPhoneticChannelOnlyForWhitelistedTerminology() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "Night Shift", aliases: [])]
        )
        let source = "Please enable Nite Shift today."

        XCTAssertLessThan(
            EntityResolver.editSimilarity("Nite Shift", "Night Shift"),
            EntityResolver.similarityThreshold
        )
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains {
            $0.surfaceText == "Nite Shift" && $0.canonical == "Night Shift"
        })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "Please enable Night Shift today."
        )
    }

    func testResolverFindsChinesePinyinCandidateInsideContinuousSentence() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "飞书", aliases: [])]
        )
        let source = "我们用菲书沟通"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertTrue(resolutions.contains {
            $0.surfaceText == "菲书" && $0.canonical == "飞书"
        })
        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "我们用飞书沟通"
        )
    }

    func testResolverPreservesAmbiguousChinesePinyinSurface() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [
                PersonalLexiconEntry(canonical: "飞书", aliases: []),
                PersonalLexiconEntry(canonical: "非书", aliases: []),
            ]
        )
        let source = "我们用菲书沟通"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertFalse(resolutions.contains { $0.surfaceText == "菲书" })
        XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
    }

    func testResolverDoesNotIgnoreChineseTonesForLowConfidenceCandidate() {
        let lexicon = PersonalLexiconDocument(
            schemaVersion: 1,
            entries: [PersonalLexiconEntry(canonical: "飞书", aliases: [])]
        )
        let source = "这不是非数值类型"

        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: lexicon,
            snippets: [],
            hotwords: [],
            context: WritingContext()
        )

        XCTAssertFalse(resolutions.contains { $0.surfaceText == "非数" })
        XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
    }

    func testResolverUsesOnlySafeAuthorizedContextForUniqueEntityCorrections() {
        let cases: [(String, String, WritingContext)] = [
            (
                "灵建这次更新先发测试组。",
                "灵简这次更新先发测试组。",
                WritingContext(
                    scene: .workChat,
                    level: .nearbyText,
                    safety: .safe,
                    textBeforeCursor: "项目统一名称是“灵简”，上一条也使用了“灵简”。"
                )
            ),
            (
                "戴量老师确认以后我再发。",
                "大梁老师确认以后我再发。",
                WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentMuseInputs: ["大梁老师刚确认了课程结构。"]
                )
            ),
            (
                "飞数文档里的目录先别改。",
                "飞书文档里的目录先别改。",
                WritingContext(
                    scene: .document,
                    level: .metadataOnly,
                    safety: .safe,
                    recentMuseInputs: ["飞书文档中的课程目录已经锁定。"]
                )
            ),
            (
                "缪斯这次构建通过以后覆盖安装。",
                "Muse这次构建通过以后覆盖安装。",
                WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentMuseInputs: ["Muse 构建已经通过，等待覆盖安装。"]
                )
            ),
        ]

        for (source, expected, context) in cases {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: source),
                expected,
                "source=\(source), resolutions=\(resolutions)"
            )
            XCTAssertTrue(resolutions.contains { $0.candidateSource == .authorizedContext })
        }
    }

    func testResolverRejectsNonAssertedContextCandidateWithoutDisablingOtherCorrection() {
        let cases: [(context: String, source: String, expected: String, rejectedCanonical: String)] = [
            (
                "旧项目曾叫“灵简”；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "如果名称定为“灵简”，目前还未确认；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "错误候选是“灵简”；“飞书”文档已经确认。",
                "灵建和飞数文档都要检查。",
                "灵建和飞书文档都要检查。",
                "灵简"
            ),
            (
                "这是同名的另一位“大梁老师”，与本次无关；“飞书”文档已经确认。",
                "戴量老师和飞数文档都要检查。",
                "戴量老师和飞书文档都要检查。",
                "大梁老师"
            ),
            (
                "旧产品 Muse 已停用，与本次无关；“飞书”文档已经确认。",
                "缪斯和飞数文档都要检查。",
                "缪斯和飞书文档都要检查。",
                "Muse"
            ),
            (
                "假设以后改名 Muse，目前没有确认；“飞书”文档已经确认。",
                "缪斯和飞数文档都要检查。",
                "缪斯和飞书文档都要检查。",
                "Muse"
            ),
        ]

        for item in cases {
            let resolutions = EntityResolver.resolve(
                segments: [segment(item.source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentMuseInputs: [item.context]
                )
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: item.source),
                item.expected,
                "context=\(item.context), resolutions=\(resolutions)"
            )
            XCTAssertFalse(
                resolutions.contains {
                    $0.candidateSource == .authorizedContext
                        && $0.canonical == item.rejectedCanonical
                },
                "context=\(item.context), resolutions=\(resolutions)"
            )
            XCTAssertTrue(resolutions.contains {
                $0.candidateSource == .authorizedContext && $0.canonical == "飞书"
            })
        }
    }

    func testResolverAcceptsCandidateWhenSameContextAlsoHasCurrentConfirmedProvenance() {
        let source = "灵建这次更新先发测试组。"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: .empty,
            snippets: [],
            hotwords: [],
            context: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .safe,
                recentMuseInputs: [
                    "旧项目曾叫“灵简”；当前项目的名称已确认为“灵简”。",
                ]
            )
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "灵简这次更新先发测试组。"
        )
    }

    func testResolverRequiresAffirmedContextEvidenceBeforeApplyingOwnedAlias() {
        let source = "缪斯和飞数文档都要检查。"
        let resolutions = EntityResolver.resolve(
            segments: [segment(source)],
            lexicon: .empty,
            snippets: [],
            hotwords: [],
            context: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .safe,
                recentMuseInputs: [
                    "Muse 不是本次产品名，不要用于当前消息；“飞书”文档已经确认。",
                ]
            )
        )

        XCTAssertEqual(
            EntityResolver.applying(resolutions, to: source),
            "缪斯和飞书文档都要检查。"
        )
        XCTAssertFalse(resolutions.contains {
            $0.candidateSource == .authorizedContext && $0.canonical == "Muse"
        })
        XCTAssertTrue(resolutions.contains {
            $0.candidateSource == .authorizedContext && $0.canonical == "飞书"
        })
    }

    func testResolverPreservesUnconfirmedOrUnauthorizedContextGuess() {
        let source = "灵建这个名字我还没确认，先保留，别替我猜。"
        for context in [
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .safe,
                textBeforeCursor: "上文有人写“灵简”。",
                textAfterCursor: "下文另一处写“灵境”。"
            ),
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .secure,
                textBeforeCursor: "项目统一名称是“灵简”。"
            ),
            WritingContext(
                scene: .workChat,
                level: .nearbyText,
                safety: .unknown,
                textBeforeCursor: "项目统一名称是“灵简”。"
            ),
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
        }
    }

    func testResolverDoesNotApplyOwnedAliasWhenUserExplicitlyRejectsTheMapping() {
        let context = WritingContext(
            scene: .workChat,
            level: .metadataOnly,
            safety: .safe,
            recentMuseInputs: ["Muse 构建已经通过。"]
        )
        for source in [
            "不要把缪斯改成 Muse。",
            "别把缪斯换成 Muse。",
            "缪斯不是 Muse，别改写。",
            "这里说的是缪斯，不是 Muse，先按原词保留。",
            "这里的缪斯并非 Muse，请原样保留。",
            "这里的缪斯与 Muse 无关，维持原词。",
            "这里的缪斯和 Muse 不是一个东西，请保留原文。",
            "这里的 Muse 不是缪斯，后一个词保持原样。",
            "Muse 与缪斯无关，请保留两个写法。",
            "不要把 Muse 改成缪斯，请保留两个写法。",
            "缪斯不是产品名，保持原样。",
            "缪斯这个写法有歧义，暂时别替换。",
            "请照录缪斯，不要纠正为 Muse。",
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: source), source)
        }

        for contextTerm in ["muse", "MUSE", "Mu-se", "Mu se", "MuseScore"] {
            let resolutions = EntityResolver.resolve(
                segments: [segment("缪斯这次构建通过以后覆盖安装。")],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: WritingContext(
                    scene: .workChat,
                    level: .metadataOnly,
                    safety: .safe,
                    recentMuseInputs: ["\(contextTerm) 构建已经通过。"]
                )
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: "缪斯这次构建通过以后覆盖安装。"),
                "缪斯这次构建通过以后覆盖安装。"
            )
        }
    }

    func testResolverDoesNotLetUnrelatedNegativeInstructionDisableOwnedAlias() {
        let context = WritingContext(
            scene: .workChat,
            level: .metadataOnly,
            safety: .safe,
            recentMuseInputs: ["Muse 构建已经通过。"]
        )
        for source in [
            "缪斯这次构建完成，不要把日志发给客户。",
            "缪斯这次构建完成，截图保持原样。",
            "缪斯这次构建完成，代码先保留，别改写说明。",
        ] {
            let resolutions = EntityResolver.resolve(
                segments: [segment(source)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(
                EntityResolver.applying(resolutions, to: source),
                source.replacingOccurrences(of: "缪斯", with: "Muse"),
                "source=\(source), resolutions=\(resolutions)"
            )
        }
    }

    func testResolverDoesNotTurnSharedAffixIntoContextCorrection() {
        for pair in [
            ("小林老师稍后确认。", "大梁老师刚确认了课程结构。"),
            ("登录失败仍在排查。", "登录流程刚更新。"),
            ("接口调试完成以后再定时间。", "接口联调排期与上线检查。"),
        ] {
            let context = WritingContext(
                scene: .workChat,
                level: .selectedText,
                safety: .safe,
                selectedText: pair.1
            )
            let resolutions = EntityResolver.resolve(
                segments: [segment(pair.0)],
                lexicon: .empty,
                snippets: [],
                hotwords: [],
                context: context
            )
            XCTAssertEqual(EntityResolver.applying(resolutions, to: pair.0), pair.0)
        }
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
