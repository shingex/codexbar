import AppKit
import CoreText
import SwiftUI
import XCTest

@MainActor
final class ReadmeScreenshotTests: CodexBarTestCase {
    func testCaptureReadmeViews() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_CAPTURE_README"] == "1" else {
            throw XCTSkip("README capture is opt-in")
        }
        _ = NSApplication.shared
        let font = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codexbar.app/Contents/Resources/hgi-stroke-rounded.ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: font.path))
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        let previousLanguage = L.languageOverride
        defer { L.languageOverride = previousLanguage }

        let now = Date()
        let accounts = try [("studio", "plus", 32.0, 48.0), ("lab", "pro", 17.0, 26.0)].map {
            id, plan, primary, secondary in
            var account = try self.makeOAuthAccount(accountID: id, email: "\(id)@example.test", planType: plan)
            account.primaryUsedPercent = primary
            account.secondaryUsedPercent = secondary
            account.primaryLimitWindowSeconds = 18_000
            account.secondaryLimitWindowSeconds = 604_800
            account.primaryResetAt = now.addingTimeInterval(9_000)
            account.secondaryResetAt = now.addingTimeInterval(259_200)
            account.lastChecked = now
            return CodexBarProviderAccount.fromTokenAccount(account, existingID: id)
        }
        let oauth = CodexBarProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI",
            activeAccountId: "studio", accounts: accounts)
        let key = CodexBarProviderAccount(id: "demo-key", kind: .apiKey, label: "Demo Key",
            apiKey: "not-a-real-key", modelSelection: .init(selectedModelID: "deepseek-v4-pro", pinnedModelIDs: ["deepseek-v4-pro"]))
        let provider = CodexBarProvider(id: "demo-deepseek", kind: .openAICompatible, label: "DeepSeek",
            enabled: true, baseURL: "https://example.test/v1", thirdPartyModelProvider: .deepSeek,
            activeAccountId: key.id, accounts: [key])
        var config = CodexBarConfig(active: .init(providerId: oauth.id, accountId: "studio"),
            providers: [oauth, provider])
        config.openAI.modelRoutingEnabled = true
        try self.writeConfig(config)
        let store = TokenStore(syncService: PreviewSync(), openAIAccountGatewayService: OpenAIAccountGatewayControllerSpy(),
            openRouterGatewayService: OpenRouterGatewayControllerSpy(), codexRunningProcessIDs: { [] })
        let updates = UpdateCoordinator()

        for (language, chinese) in [("zh", true), ("en", false)] {
            L.languageOverride = chinese
            try self.capture("menu-\(language)", size: NSSize(width: 400, height: 520),
                view: MenuBarView(versionDisplay: "2.0.0")
                    .environmentObject(store)
                    .environmentObject(OAuthManager())
                    .environmentObject(updates)
                    .background(Color(nsColor: .windowBackgroundColor)))
            try self.capture("settings-\(language)", size: NSSize(width: 980, height: 720), titled: true,
                view: SettingsWindowView(store: store, updateCoordinator: updates,
                    codexAppPathPanelService: .shared, selectedPage: .accounts, onClose: {}))
        }
    }

    private func capture(_ name: String, size: NSSize, titled: Bool = false, view: some View) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: titled ? [.titled, .closable] : [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let top = host.isFlipped ? bounds.minY : bounds.maxY - 292
        let region = titled
            ? NSRect(x: L.zh ? 148 : 194, y: top, width: L.zh ? 832 : 786, height: 292)
            : bounds
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: region))
        host.cacheDisplay(in: region, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }
}

private struct PreviewSync: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}
