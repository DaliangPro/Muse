import XCTest
@testable import Muse

final class NormalOutputSettingsTests: XCTestCase {
    func testPhraseReplacementRemainsAvailableWithoutBecomingAnASRHotword() {
        let phrase = "您好，材料已收到。稍后给您回复。"
        let document = TerminologyDocument(entries: [
            TerminologyEntry(canonicalText: phrase, aliases: [.init(text: "确认收件", source: .manual)], origin: .manual),
            TerminologyEntry(canonicalText: "Muse", aliases: [.init(text: "木思", source: .manual)], origin: .manual)
        ])
        let projection = TerminologyProjections.make(from: document)
        XCTAssertEqual(projection.hotwords, ["Muse"])
        XCTAssertEqual(projection.corrections["确认收件"], phrase)
        XCTAssertEqual(projection.corrections["木思"], "Muse")
    }

    func testVisibleModesGroupDirectAndLightWithoutChangingStoredModes() {
        var light = ProcessingMode.lightPolish
        light.prompt = "我的轻度要求"
        let custom = ProcessingMode.newCustomMode(name: "自定义输出")
        let stored: [ProcessingMode] = [.direct, light, .formalWriting, .translate, custom]
        let visible = NormalOutputSettings.visibleModes(in: stored, light: true)
        XCTAssertEqual(visible.map(\.id), [light.id, ProcessingMode.formalWriting.id, ProcessingMode.translate.id, custom.id])
        XCTAssertEqual(visible.first?.prompt, "我的轻度要求")
        XCTAssertEqual(visible.first?.name, L("正常输出", "Normal Output"))
        XCTAssertEqual(visible.first?.hotkeyCode, ProcessingMode.direct.hotkeyCode)
        XCTAssertEqual(visible.first?.hotkeyModifiers, ProcessingMode.direct.hotkeyModifiers)
        XCTAssertEqual(stored[1].name, light.name)
        XCTAssertEqual(stored.count, 5)
    }

    func testEitherLegacyNormalShortcutUsesTheChosenProcessor() {
        let modes: [ProcessingMode] = [.direct, .lightPolish, .formalWriting]
        XCTAssertEqual(NormalOutputSettings.resolve(.direct, in: modes, light: true).id, ProcessingMode.lightPolishId)
        XCTAssertEqual(NormalOutputSettings.resolve(.lightPolish, in: modes, light: false).id, ProcessingMode.directId)
        XCTAssertEqual(NormalOutputSettings.resolve(.formalWriting, in: modes, light: true), .formalWriting)
    }

    func testNewPreferenceDefaultsToDirectAndPersistsLightSelection() {
        let suite = "NormalOutputSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(NormalOutputSettings.usesLightPolish(defaults: defaults))
        defaults.set(true, forKey: NormalOutputSettings.preferenceKey)
        XCTAssertTrue(NormalOutputSettings.usesLightPolish(defaults: defaults))
    }
}
