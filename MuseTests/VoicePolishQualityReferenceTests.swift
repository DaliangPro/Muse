import Foundation
import XCTest
@testable import Muse

final class VoicePolishQualityReferenceTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "quality-reference",
        baseURL: "https://example.com/v1"
    )

    func test77条人工参考成稿全部可通过正式Pipeline校验() async throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 77)
        var failures: [String] = []

        for fixture in fixtures {
            let client = QualityReferenceLLM(output: fixture.referenceOutput)
            let request = makeRequest(for: fixture)
            let sourceFactSegments = fixture.scene == .code
                ? request.input.segments
                : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                    from: request.input.segments
                )
            let sourceFacts = ProtectedFactExtractor.extract(from: sourceFactSegments)
            let directValidation = VoicePolishValidator.validateFast(
                output: fixture.referenceOutput,
                request: request,
                sourceFacts: sourceFacts
            )
            let result = await VoicePolishPipeline(client: client, config: config).process(request)
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
                failures.append(
                    "\(fixture.id): fallback=\(result.usedFallback) "
                    + "codes=\(directValidation.codes.map { $0.rawValue }) "
                    + "sourceFacts=\(factDescription(sourceFacts)) "
                    + "outputFacts=\(factDescription(outputFacts)) "
                    + "layout=\(expectation.kind.rawValue)/"
                    + "expected:\(expectedCount)/"
                    + "minimum:\(minimumCount)/"
                    + "numbering:\(expectation.numberingPreference.rawValue)/"
                    + "declaredMatches:\(String(describing: VoicePolishListCountConsistency.declaredCountMatchesList(in: fixture.referenceOutput))) "
                    + "output=\(result.text)"
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
    }

    struct Variant: Decodable {
        let id: String
        let baseCaseId: String
        let spokenInput: String
        let preconditions: [String]?
    }

    struct Fixture {
        let id: String
        let scene: WritingScene
        let spokenInput: String
        let referenceOutput: String
        let preconditions: [String]
    }

    func loadFixtures() throws -> [Fixture] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let datasetURL = repositoryRoot
            .appendingPathComponent("docs/2026-08-12-Muse-Voice-Polish-Quality-Test-Set.json")
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
                preconditions: $0.preconditions ?? []
            )
        }
        let variantFixtures = try dataset.stressVariants.map { variant in
            let base = try XCTUnwrap(baseByID[variant.baseCaseId], variant.id)
            return Fixture(
                id: variant.id,
                scene: base.writingScene,
                spokenInput: variant.spokenInput,
                referenceOutput: base.referenceOutput,
                preconditions: (base.preconditions ?? []) + (variant.preconditions ?? [])
            )
        }
        return baseFixtures + variantFixtures
    }

    func makeRequest(for fixture: Fixture) -> VoicePolishRequest {
        let terminology = terminologyRules(from: fixture.preconditions)
        let canonical = EntityResolver.applyingKnownCorrections(
            terminology,
            to: fixture.spokenInput
        )
        let rawSegment = RecognitionSegment(
            id: "s1",
            text: fixture.spokenInput,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        let canonicalSegment = RecognitionSegment(
            id: "s1",
            text: canonical,
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        let edits = terminology.compactMap { alias, replacement -> VoiceTerminologyEdit? in
            guard EntityResolver.applyingKnownCorrections(
                [alias: replacement],
                to: fixture.spokenInput
            ) != fixture.spokenInput else { return nil }
            return VoiceTerminologyEdit(
                alias: alias,
                canonical: replacement,
                sourceSegmentIDs: ["s1"]
            )
        }
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: fixture.spokenInput,
                rawSegments: [rawSegment],
                canonicalText: canonical,
                segments: [canonicalSegment],
                requiredEntityEdits: edits,
                durationMs: 0,
                provider: .volcano
            ),
            context: WritingContext(
                scene: fixture.scene,
                level: .metadataOnly,
                safety: .unknown
            ),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
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
}

private actor QualityReferenceLLM: LLMClient {
    let output: String

    init(output: String) {
        self.output = output
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        LLMResponse(text: output, model: config.model)
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
