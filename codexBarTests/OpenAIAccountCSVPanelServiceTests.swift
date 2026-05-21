import Foundation
import XCTest

@MainActor
final class OpenAIAccountCSVPanelServiceTests: XCTestCase {
    func testExportRequestsSavePanelAfterActivation() {
        var didActivate = false
        var didRequestSavePanel = false
        let expectedURL = URL(fileURLWithPath: "/tmp/export.csv")
        let service = OpenAIAccountCSVPanelService(
            activateApp: { didActivate = true },
            requestExportURLAction: { _ in
                didRequestSavePanel = true
                return expectedURL
            },
            requestImportURLAction: { nil }
        )

        XCTAssertEqual(service.requestExportURL(), expectedURL)
        XCTAssertTrue(didActivate)
        XCTAssertTrue(didRequestSavePanel)
    }

    func testExportPassesSuggestedJSONFilenameToSavePanel() {
        var receivedFilename: String?
        let expectedURL = URL(fileURLWithPath: "/tmp/export.csv")
        let service = OpenAIAccountCSVPanelService(
            activateApp: {},
            requestExportURLAction: { suggestedFilename in
                receivedFilename = suggestedFilename
                return expectedURL
            },
            requestImportURLAction: { nil }
        )

        XCTAssertEqual(service.requestExportURL(), expectedURL)
        XCTAssertEqual(receivedFilename?.hasPrefix("rhino2api-account-"), true)
        XCTAssertEqual(receivedFilename?.hasSuffix(".json"), true)
    }

    func testImportCancelReturnsNil() {
        var didActivate = false
        let service = OpenAIAccountCSVPanelService(
            activateApp: { didActivate = true },
            requestExportURLAction: { _ in nil },
            requestImportURLAction: { nil }
        )

        XCTAssertNil(service.requestImportURL())
        XCTAssertTrue(didActivate)
    }

    func testAddOpenAIAccountMenuCopyStaysStable() {
        L.languageOverride = true
        defer { L.languageOverride = nil }

        XCTAssertEqual(L.addOpenAIAccountMenu, "添加 OpenAI 账号")
        XCTAssertEqual(L.gettingStartedOpenAIAuthButton, "在线认证")
        XCTAssertEqual(L.gettingStartedOpenAIImportButton, "导入")
    }
}
