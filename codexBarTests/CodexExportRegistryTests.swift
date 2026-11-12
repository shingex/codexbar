import Foundation
import XCTest

final class CodexExportRegistryTests: CodexBarTestCase {
    func testDefaultsPreserveOldConfiguration() throws {
        XCTAssertEqual(CodexBarOpenAISettings().modelRoutingStyle, .catalog)
        XCTAssertEqual(try JSONDecoder().decode(CodexBarOpenAISettings.self, from: Data("{}".utf8)).modelRoutingStyle, .follow)
    }
    func testNativeNameAndSlugCollisionsOnlyRenameExports() throws {
        let key = CodexBarProviderAccount(id: "work", kind: .apiKey, label: "Work", apiKey: "fixture-secret",
            modelSelection: .init(pinnedModelIDs: ["gpt-5", "GPT-5.1", "gpt-5.2", "unrelated"]))
        let second = CodexBarProviderAccount(id: "personal", kind: .apiKey, label: "Personal", apiKey: "other-fixture",
            modelSelection: .init(pinnedModelIDs: ["gpt-5"]))
        let provider = CodexBarProvider(id: "relay", kind: .openAICompatible, label: "Relay",
            baseURL: "https://example.test", accounts: [key, second])
        let config = CodexBarConfig(providers: [provider])
        let source = Data(#"{"models":[{"slug":"gpt-5","display_name":"GPT-5 Native","visibility":"list"},{"slug":"native-snapshot","display_name":"GPT-5.1"},{"slug":"gpt-5.2","display_name":"Official 5.2"},{"slug":"another-native","display_name":"GPT-5 (Relay · Work)"},{"slug":"codexbar","display_name":"CodexBar"}]}"#.utf8)
        let first = try CodexExportRegistry.catalog(config: config, source: source)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let rows = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["slug"] as? String, "gpt-5")
        XCTAssertEqual(rows.first?["display_name"] as? String, "GPT-5 Native")
        XCTAssertEqual(rows.first?["visibility"] as? String, "list")

        let entries = CodexExportRegistry.load().entries
        let work = try XCTUnwrap(entries.first { $0.account == key.id && $0.model == "gpt-5" })
        let exportedNames = rows.filter { ($0["slug"] as? String)?.hasPrefix("codexbar-") == true }
            .compactMap { $0["display_name"] as? String }
        XCTAssertEqual(Set(exportedNames), ["gpt-5 (Relay · Work) 2", "gpt-5 (Relay · Personal)", "GPT-5.1 (Relay)", "gpt-5.2 (Relay)", "unrelated"])
        guard case .compatibleProvider(let target) = CodexExportRegistry.target(work, config: config) else {
            return XCTFail("Expected the original provider target")
        }
        XCTAssertEqual(target.modelID, "gpt-5")
        XCTAssertEqual(target.accountID, key.id)
        XCTAssertEqual(try CodexExportRegistry.catalog(config: config, source: first), first)
        XCTAssertEqual(CodexExportRegistry.load().entries.map(\.id), entries.map(\.id))
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
