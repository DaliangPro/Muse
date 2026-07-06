import XCTest
@testable import Muse

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
        }
    }

    func testResolvedModeFallsBackToDirectForUnavailableProvider() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        // Custom/LLM modes should always be supported
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .volcano))
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .apple))
    }

    func testSupportedModesFilterKeepsAllForAvailableProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, customMode]

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let appleModes = ASRProviderRegistry.supportedModes(from: modes, for: .apple)
        XCTAssertEqual(appleModes.map(\.id), [ProcessingMode.directId, customMode.id])
    }
}
