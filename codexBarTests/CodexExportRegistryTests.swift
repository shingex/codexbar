import Foundation
import XCTest

final class CodexExportRegistryTests: CodexBarTestCase {
    func testDefaultsPreserveOldConfiguration() throws {
        XCTAssertEqual(CodexBarOpenAISettings().modelRoutingStyle, .catalog)
        XCTAssertEqual(try JSONDecoder().decode(CodexBarOpenAISettings.self, from: Data("{}".utf8)).modelRoutingStyle, .follow)
    }
    func testStableEntriesDoNotLeakSecretsAndResolveTheirOwnModel() throws {
        let key = CodexBarProviderAccount(id: "one", kind: .apiKey, label: "Work", apiKey: "fixture-secret", modelSelection: .init(pinnedModelIDs: ["a", "b"]))
        var provider = CodexBarProvider(id: "provider", kind: .openAICompatible, label: "Provider", baseURL: "https://example.test", accounts: [key])
        var config = CodexBarConfig(providers: [provider])
        let source = Data(#"{"models":[{"slug":"official","context_window":200000},{"slug":"codexbar","context_window":200000}]}"#.utf8)
        let first = try CodexExportRegistry.catalog(config: config, source: source)
        let entries = CodexExportRegistry.load().entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("fixture-secret"))
        guard case .compatibleProvider(let target) = CodexExportRegistry.target(entries[1], config: config) else { return XCTFail("missing target") }
        XCTAssertEqual(target.modelID, "b")
        provider.label = "Renamed"
        config.providers = [provider]
        _ = try CodexExportRegistry.catalog(config: config, source: first)
        XCTAssertEqual(CodexExportRegistry.load().entries.map(\.id), entries.map(\.id))
        config.providers = []
        XCTAssertNil(CodexExportRegistry.target(entries[0], config: config))
    }
}
