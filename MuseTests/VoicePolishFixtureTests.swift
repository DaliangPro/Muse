import XCTest
@testable import Muse

final class VoicePolishFixtureTests: XCTestCase {
    func testCatalogContainsExactlyOneHundredFixturesWithRequiredDistribution() {
        XCTAssertEqual(VoicePolishFixtureCatalog.all.count, 100)
        XCTAssertEqual(Set(VoicePolishFixtureCatalog.all.map(\.id)).count, 100)
        for category in VoicePolishFixtureCategory.allCases {
            XCTAssertEqual(
                VoicePolishFixtureCatalog.all.filter { $0.category == category }.count,
                category.expectedCount,
                category.rawValue
            )
        }
    }

    func testAllFixturesMeetDeterministicRouteAndCanonicalFactExpectations() {
        for fixture in VoicePolishFixtureCatalog.all {
            let request = VoicePolishRequest(
                input: VoiceInputEnvelope(
                    providerFinalText: fixture.sourceText,
                    segments: fixture.segments,
                    durationMs: 3_000,
                    provider: .volcano
                ),
                context: WritingContext(scene: fixture.scene),
                preferences: UserPolishPreferences(additionalRequirements: ""),
                qualityMode: .balanced
            )
            let facts = ProtectedFactExtractor.extract(from: fixture.segments)
            let decision = VoicePolishComplexityRouter.decide(
                request: request,
                factCandidates: facts
            )

            XCTAssertEqual(decision.route, fixture.expectedRoute, fixture.id)
            let canonical = Set(facts.compactMap(\.canonicalValue))
            for expected in fixture.mustPreserveCanonicalFacts + fixture.supersededCanonicalFacts {
                XCTAssertTrue(canonical.contains(expected), "\(fixture.id) 缺少 canonical fact \(expected)")
            }
            XCTAssertTrue(fixture.segments.allSatisfy { !$0.id.isEmpty && $0.isFinal }, fixture.id)
        }
    }
}
