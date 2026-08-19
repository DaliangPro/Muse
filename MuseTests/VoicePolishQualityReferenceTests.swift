import Foundation
import XCTest
@testable import Muse

final class VoicePolishQualityReferenceTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "quality-reference",
        baseURL: "https://example.com/v1"
    )

    func test130条多维人工参考成稿全部可通过正式Pipeline校验() async throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 130)
        var failures: [String] = []

        for fixture in fixtures {
            let request = makeRequest(for: fixture)
            let sourceFactSegments = fixture.scene == .code
                ? request.input.segments
                : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                    from: request.input.segments
                )
            let sourceFacts = ProtectedFactExtractor.extract(from: sourceFactSegments)
            let plan = referencePlan(
                output: fixture.referenceOutput,
                request: request,
                sourceFacts: sourceFacts
            )
            let client = try QualityReferenceLLM(
                output: fixture.referenceOutput,
                plan: plan
            )
            let directValidation = VoicePolishValidator.validateFast(
                output: fixture.referenceOutput,
                request: request,
                sourceFacts: sourceFacts
            )
            // 参考成稿替身每次只能返回整篇冻结答案；分片可靠性由专门的
            // Pipeline 测试覆盖，这里关闭内部分片以单独验证整篇参考成稿
            // 能否通过与生产相同的事实、结构和安全门禁。
            let result = await VoicePolishPipeline(
                client: client,
                config: config,
                fastChunkSourceTokenLimit: Int.max
            ).process(request)
            if result.usedFallback || result.text != fixture.referenceOutput {
                let expectation = VoicePolishLayoutExpectation.infer(from: request)
                let expectedCount = expectation.expectedListItemCount.map(String.init) ?? "nil"
                let minimumCount = expectation.minimumListItemCount.map(String.init) ?? "nil"
                let outputFactText = fixture.scene == .code
                    ? fixture.referenceOutput
                    : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                        in: fixture.referenceOutput
                    )
                let outputFacts = ProtectedFactExtractor.extract(from: [RecognitionSegment(
                    id: "output",
                    text: outputFactText,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )])
                let superseded = VoicePolishValidator.locallySupersededFactIndices(
                    request: request,
                    sourceFacts: sourceFacts
                ).sorted().map { index in
                    "\(index):\(sourceFacts[index].sourceText)"
                }.joined(separator: "|")
                failures.append(
                    "\(fixture.id): fallback=\(result.usedFallback) "
                    + "resultCodes=\(result.validationCodes.map { $0.rawValue }) "
                    + "directCodes=\(directValidation.codes.map { $0.rawValue }) "
                    + "negative=\(VoicePolishValidator.protectedNegativeIntentFailures(output: fixture.referenceOutput, request: request)) "
                    + "sourceFacts=\(factDescription(sourceFacts)) "
                    + "outputFacts=\(factDescription(outputFacts)) "
                    + "superseded=\(superseded) "
                    + "layout=\(expectation.kind.rawValue)/"
                    + "expected:\(expectedCount)/"
                    + "minimum:\(minimumCount)/"
                    + "numbering:\(expectation.numberingPreference.rawValue)/"
                    + "declaredMatches:\(String(describing: VoicePolishListCountConsistency.declaredCountMatchesList(in: fixture.referenceOutput))) "
                    + "outputLength=\(result.text.count)"
                )
            }
        }

        if !failures.isEmpty {
            print(failures.joined(separator: "\n"))
            XCTFail(
                "人工参考成稿被正式链路拒绝 \(failures.count) 条：\n"
                + failures.prefix(12).joined(separator: "\n")
            )
        }
    }

    func test安全上下文实体解析不会把测试集旁注写进正文() throws {
        let fixtures = try loadFixtures().filter { $0.contextFixture != nil }
        var failures: [String] = []

        for fixture in fixtures {
            let request = makeRequest(for: fixture)
            let reference = fixture.referenceOutput
                .precomposedStringWithCompatibilityMapping
                .lowercased()
                .filter { !$0.isWhitespace && !$0.isPunctuation }
            for resolution in request.resolvedEntities where
                resolution.candidateSource == .authorizedContext
                    && resolution.surfaceText != resolution.canonical {
                let canonical = resolution.canonical
                    .precomposedStringWithCompatibilityMapping
                    .lowercased()
                    .filter { !$0.isWhitespace && !$0.isPunctuation }
                if canonical.isEmpty || !reference.contains(canonical) {
                    failures.append(
                        "\(fixture.id): \(resolution.surfaceText) → \(resolution.canonical)"
                    )
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "安全上下文解析产生了参考正文不支持的替换：\n\(failures.joined(separator: "\n"))"
        )
    }

    func test六千与近八千字样本真实跨越内部切片完成改口() throws {
        let fixtures = Dictionary(uniqueKeysWithValues: try loadFixtures().map { ($0.id, $0) })
        let expectations = [
            (
                id: "natural-long-09",
                old: "质量修复重试次数先按三次",
                final: "质量修复的重试次数我说错了",
                minimumChunkCount: 4
            ),
            (
                id: "natural-long-10",
                old: "课程资料复核先安排三轮",
                final: "课程资料复核轮次不对",
                minimumChunkCount: 5
            ),
        ]

        for expectation in expectations {
            let fixture = try XCTUnwrap(fixtures[expectation.id])
            let request = makeRequest(for: fixture)
            let canonicalSource = request.fallbackText
            let chunks = VoicePolishPipeline.fastChunkTexts(from: canonicalSource)
            let oldIndex = try XCTUnwrap(chunks.firstIndex {
                $0.contains(expectation.old)
            })
            let finalIndex = try XCTUnwrap(chunks.firstIndex {
                $0.contains(expectation.final)
            })

            XCTAssertGreaterThanOrEqual(
                chunks.count,
                expectation.minimumChunkCount,
                expectation.id
            )
            XCTAssertNotEqual(oldIndex, finalIndex, "\(expectation.id) 未真实跨内部切片")
        }

        let contextFixture = try XCTUnwrap(fixtures["natural-long-09"])
        let contextRequest = makeRequest(for: contextFixture)
        XCTAssertTrue(
            contextRequest.fallbackText.contains("Muse进程")
                || contextRequest.fallbackText.contains("Muse 进程")
        )
        XCTAssertFalse(contextRequest.fallbackText.contains("缪斯进程"))

        let dirtyNearEightThousand = try XCTUnwrap(
            fixtures["natural-long-10-asr-dirty-segments-2"]
        )
        let dirtyRequest = makeRequest(for: dirtyNearEightThousand)
        let dirtyFacts = ProtectedFactExtractor.extract(from: dirtyRequest.input.segments)
        let dirtyOccurrences = VoicePolishValidator.locallySupersededFactOccurrences(
            request: dirtyRequest,
            sourceFacts: dirtyFacts
        )
        XCTAssertTrue(dirtyOccurrences.contains { occurrence in
            occurrence.relationAnchor == "课程资料复核"
                && dirtyFacts[occurrence.factIndex].canonicalValue == "3"
                && occurrence.replacementFactIndex.map {
                    dirtyFacts[$0].canonicalValue == "2"
                } == true
        })
        let initialChunks = VoicePolishPipeline.fastChunkTexts(
            from: dirtyRequest.fallbackText
        )
        let recoveryChunks = try XCTUnwrap(
            VoicePolishPipeline.fastChunkRecoveryTexts(from: initialChunks[0])
        )
        let expandedChunks = recoveryChunks + Array(initialChunks.dropFirst())
        let dispositions = VoicePolishPipeline.factDispositionsByChunk(
            request: dirtyRequest,
            chunks: expandedChunks,
            sourceFacts: dirtyFacts,
            supersededOccurrences: dirtyOccurrences
        )
        XCTAssertTrue(
            dispositions[1].superseded.contains("number|3"),
            "失败片二分后仍错误要求恢复已作废的课程资料复核三轮"
        )
    }
}

private extension VoicePolishQualityReferenceTests {
    struct Dataset: Decodable {
        let cases: [BaseCase]
        let stressVariants: [Variant]
    }

    struct BaseCase: Decodable {
        let id: String
        let writingScene: WritingScene
        let spokenInput: String
        let referenceOutput: String
        let preconditions: [String]?
        let segmentTexts: [String]
        let contextFixture: ContextFixture?
    }

    struct Variant: Decodable {
        let id: String
        let baseCaseId: String
        let spokenInput: String
        let preconditions: [String]?
        let segmentTexts: [String]
        let contextFixture: ContextFixture?
    }

    struct ContextFixture: Decodable {
        let level: WritingContextLevel
        let safety: ContextSafety
        let selectedText: String?
        let textBeforeCursor: String?
        let textAfterCursor: String?
        let recentMuseInputs: [String]
    }

    struct Fixture {
        let id: String
        let scene: WritingScene
        let spokenInput: String
        let referenceOutput: String
        let preconditions: [String]
        let segmentTexts: [String]
        let contextFixture: ContextFixture?
    }

    func loadFixtures() throws -> [Fixture] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let datasetURL = repositoryRoot
            .appendingPathComponent("docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dataset = try decoder.decode(Dataset.self, from: Data(contentsOf: datasetURL))
        let baseByID = Dictionary(uniqueKeysWithValues: dataset.cases.map { ($0.id, $0) })
        let baseFixtures = dataset.cases.map {
            Fixture(
                id: $0.id,
                scene: $0.writingScene,
                spokenInput: $0.spokenInput,
                referenceOutput: $0.referenceOutput,
                preconditions: $0.preconditions ?? [],
                segmentTexts: $0.segmentTexts,
                contextFixture: $0.contextFixture
            )
        }
        let variantFixtures = try dataset.stressVariants.map { variant in
            let base = try XCTUnwrap(baseByID[variant.baseCaseId], variant.id)
            return Fixture(
                id: variant.id,
                scene: base.writingScene,
                spokenInput: variant.spokenInput,
                referenceOutput: base.referenceOutput,
                preconditions: (base.preconditions ?? []) + (variant.preconditions ?? []),
                segmentTexts: variant.segmentTexts,
                contextFixture: variant.contextFixture
            )
        }
        return baseFixtures + variantFixtures
    }

    func makeRequest(for fixture: Fixture) -> VoicePolishRequest {
        let terminology = terminologyRules(from: fixture.preconditions)
        let rawSegments = fixture.segmentTexts.enumerated().map { index, text in
            RecognitionSegment(
                id: "s\(index + 1)",
                text: text,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        let canonicalSegments = rawSegments.map { segment in
            RecognitionSegment(
                id: segment.id,
                text: EntityResolver.applyingKnownCorrections(terminology, to: segment.text),
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        let canonical = canonicalSegments.map(\.text).joined()
        let edits = terminology.compactMap { alias, replacement -> VoiceTerminologyEdit? in
            let sourceSegmentIDs = rawSegments.compactMap { segment -> String? in
                EntityResolver.applyingKnownCorrections([alias: replacement], to: segment.text)
                    == segment.text ? nil : segment.id
            }
            guard !sourceSegmentIDs.isEmpty else { return nil }
            return VoiceTerminologyEdit(
                alias: alias,
                canonical: replacement,
                sourceSegmentIDs: sourceSegmentIDs
            )
        }
        let context = fixture.contextFixture.map {
            WritingContext(
                scene: fixture.scene,
                level: $0.level,
                safety: $0.safety,
                selectedText: $0.selectedText,
                textBeforeCursor: $0.textBeforeCursor,
                textAfterCursor: $0.textAfterCursor,
                recentMuseInputs: $0.recentMuseInputs
            )
        } ?? WritingContext(
            scene: fixture.scene,
            level: .metadataOnly,
            safety: .unknown
        )
        let resolvedEntities = EntityResolver.resolve(
            segments: canonicalSegments,
            lexicon: .empty,
            snippets: [],
            hotwords: [],
            context: context
        )
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: fixture.spokenInput,
                rawSegments: rawSegments,
                canonicalText: canonical,
                segments: canonicalSegments,
                requiredEntityEdits: edits,
                durationMs: 0,
                provider: .volcano
            ),
            context: context,
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic,
            resolvedEntities: resolvedEntities
        )
    }

    func terminologyRules(from preconditions: [String]) -> [String: String] {
        var rules: [String: String] = [:]
        for precondition in preconditions {
            guard let arrow = precondition.range(of: "→") else { continue }
            var alias = String(precondition[..<arrow.lowerBound])
            if let marker = alias.range(of: "已确认 ", options: .backwards) {
                alias = String(alias[marker.upperBound...])
            }
            alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = String(precondition[arrow.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty, !canonical.isEmpty {
                rules[alias] = canonical
            }
        }
        return rules
    }

    func factDescription(_ facts: [SourceFactCandidate]) -> String {
        facts.map {
            "\($0.kind.rawValue):\($0.sourceText):\($0.canonicalValue ?? "nil")"
        }.joined(separator: "|")
    }

    func referencePlan(
        output: String,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> VoicePolishPlan {
        let superseded = VoicePolishValidator.locallySupersededFactIndices(
            request: request,
            sourceFacts: sourceFacts
        )
        let facts = sourceFacts.enumerated().map { index, candidate in
            ProtectedFact(
                sourceText: candidate.sourceText,
                canonicalValue: candidate.canonicalValue,
                kind: candidate.kind,
                disposition: superseded.contains(index) ? .superseded : .mustPreserve,
                exclusionReason: nil,
                sourceSegmentIDs: candidate.sourceSegmentIDs
            )
        }
        let corrections = superseded.sorted().map { index in
            let fact = sourceFacts[index]
            return VoiceCorrection(
                previousText: fact.sourceText,
                finalText: output,
                sourceSegmentIDs: fact.sourceSegmentIDs,
                isFinal: true
            )
        }
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        return VoicePolishPlan(
            version: VoicePolishPrompts.version,
            language: request.input.detectedLanguage,
            scene: request.context.scene,
            finalIntent: "按最终意图整理为可直接使用的成稿",
            orderedBlocks: [VoicePolishBlock(
                id: "b1",
                text: output,
                sourceSegmentIDs: request.input.segments.map(\.id),
                kind: .content
            )],
            discardedFragments: [],
            corrections: corrections,
            sideNotes: [],
            facts: facts,
            uncertainEntities: [],
            outputFormat: VoiceOutputFormat(
                kind: expectation.kind,
                expectedListCount: expectation.expectedListItemCount
            ),
            confidence: 1
        )
    }
}

private actor QualityReferenceLLM: LLMClient {
    let output: String
    let encodedPlan: String
    let encodedStructuredResponse: String

    init(output: String, plan: VoicePolishPlan) throws {
        self.output = output
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        encodedPlan = String(data: try encoder.encode(plan), encoding: .utf8)!
        encodedStructuredResponse = String(
            data: try encoder.encode(StructuredVoicePolishResponse(
                plan: plan,
                finalText: output
            )),
            encoding: .utf8
        )!
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        let text: String
        switch request.task {
        case .voicePolishAnalyze:
            text = encodedPlan
        case .voicePolishStructured:
            text = encodedStructuredResponse
        case .voicePolishRepair where request.options.responseFormat == .jsonObject:
            text = encodedStructuredResponse
        default:
            text = output
        }
        return LLMResponse(text: text, model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        output
    }

    func warmUp(baseURL: String) async {}
}
