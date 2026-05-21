import XCTest

final class CodexBarOpenAIAccountUsageModeTests: XCTestCase {
    private var originalLanguageOverride: Bool?

    override func setUp() {
        super.setUp()
        self.originalLanguageOverride = L.languageOverride
    }

    override func tearDown() {
        L.languageOverride = self.originalLanguageOverride
        super.tearDown()
    }

    func testMenuToggleTitlesUseRequestedChineseCopy() {
        L.languageOverride = true

        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "手动")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "聚合")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.hybridProvider.menuToggleTitle, "混合")
    }

    func testMenuToggleTitlesUseCompactEnglishCopy() {
        L.languageOverride = false

        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "Manual")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "Aggregate")
        XCTAssertEqual(CodexBarOpenAIAccountUsageMode.hybridProvider.menuToggleTitle, "Hybrid")
    }

    func testUsageModeOrderKeepsSwitchOnTheLeftAndAggregateOnTheRight() {
        XCTAssertEqual(
            CodexBarOpenAIAccountUsageMode.allCases,
            [.switchAccount, .aggregateGateway, .hybridProvider]
        )
    }

    func testChineseActionCopySeparatesSwitchFromProviderUse() {
        L.languageOverride = true

        XCTAssertEqual(L.openAIAccountSwitchAction, "切换")
        XCTAssertEqual(L.providerUseAction, "使用")
        XCTAssertEqual(L.switchBtn, "切换")
        XCTAssertEqual(L.useBtn, "使用")
        XCTAssertTrue(L.accountUsageModeHybridHint.contains("Provider/OpenRouter 的使用"))
        XCTAssertTrue(L.openAIHybridPanelHint.contains("刷新时间跟随上方成本统计"))
        XCTAssertTrue(L.openAIHybridOAuthAccountsHint.contains("这些 OAuth 账号仍用于登录态"))
    }
}
