import AppKit
import CoreText
import SwiftUI
import XCTest

@MainActor
final class MenuPanelPresentationTests: CodexBarTestCase {
    private var logoBundle: Bundle {
        let appURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("codexbar.app")
        return Bundle(url: appURL)!
    }
    override func setUpWithError() throws {
        try super.setUpWithError()
        let fontURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codexbar.app/Contents/Resources/hgi-stroke-rounded.ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fontURL.path))
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }

    func testActiveBrandLogosKeepOriginalColorsWithoutChangingStatusTemplates() throws {
        let sources = [MenuBarModelIconLibrary.claude, MenuBarModelIconLibrary.gemini, MenuBarModelIconLibrary.deepSeek,
            MenuBarModelIconLibrary.qwen, MenuBarModelIconLibrary.kimi, MenuBarModelIconLibrary.mistral]
        for source in sources {
            let image = try XCTUnwrap(source.makeBrandImage(bundle: logoBundle))
            XCTAssertFalse(image.isTemplate)
            XCTAssertTrue(try XCTUnwrap(source.makeTemplateImage(accessibilityDescription: "")).isTemplate)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            var coloredPixels = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                    let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                    if channels.max()! - channels.min()! > 0.1 { coloredPixels += 1 }
                }
            }
            XCTAssertGreaterThan(coloredPixels, 5)
        }
        XCTAssertNil(MenuBarModelIconLibrary.openAI.makeBrandImage(bundle: logoBundle))
        for dark in [false, true] {
            let row = HStack(spacing: 12) {
                ForEach(sources.indices, id: \.self) { index in
                    MenuPanelLogo(source: sources[index], size: 48, usesBrandColors: true)
                }
            }.padding(16).background(Color(white: dark ? 0.14 : 0.96))
                .foregroundColor(.purple).tint(.purple)
                .environment(\.menuPanelLogoBundle, logoBundle)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: row)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame.size = host.fittingSize
            try capture(host, name: dark ? "brand-logos-dark" : "brand-logos-light")
        }
    }

    func testBrandedNativeMenusKeepTemplateImagesInBothAppearances() throws {
        func popup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap { popup(in: $0) }.first
        }
        for dark in [false, true] {
            let root = Menu {
                MenuPanelAction(title: "Language", icon: .languages, action: {})
                MenuPanelAction(title: "Restart", icon: .refresh04, action: {})
                MenuPanelAction(title: "Quit", icon: .power, action: {})
                MenuPanelAction(title: "Add", icon: .addSquare, action: {})
                MenuPanelAction(title: "Edit", icon: .edit02, action: {})
                MenuPanelAction(title: "Delete", icon: .delete, role: .destructive, action: {})
            } label: { MenuPanelMoreLabel(tint: .purple) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().menuPanelIconControl()
            .foregroundColor(.purple).tint(.purple).accentColor(.purple)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 100, height: 60),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let button = try XCTUnwrap(popup(in: host))
            let menu = try XCTUnwrap(button.menu)
            var inspected = false
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                let images = menu.items.compactMap(\.image)
                XCTAssertEqual(images.count, 6)
                XCTAssertTrue(images.allSatisfy(\.isTemplate), "Toolbar tint must not strip native menu template semantics")
                inspected = true
                menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            timer.invalidate()
            window.orderOut(nil)
            XCTAssertTrue(inspected)
        }
    }

    func testNativeHoverTrackingHighlightsAndDoesNotInterceptClicks() throws {
        let view = MenuPanelHoverTrackingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertNil(view.hitTest(NSPoint(x: 12, y: 12)))
        var states: [Bool] = []
        view.onHoverChanged = { states.append($0) }
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: enter)
        XCTAssertTrue(view.isHovered)
        XCTAssertGreaterThan(try XCTUnwrap(view.layer?.backgroundColor).alpha, 0)
        view.mouseExited(with: exit)
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(try XCTUnwrap(view.layer?.backgroundColor).alpha, 0)
        view.isEnabled = false
        view.mouseEntered(with: enter)
        XCTAssertFalse(view.isHovered)
    }

    func testMenuIconsRenderAsTemplatesInLightAndDarkAppearance() throws {
        let icons: [Hugeicons] = [.languages, .refresh04, .power, .addSquare, .edit02, .delete]
        for dark in [false, true] {
            let row = HStack(spacing: 8) {
                ForEach(icons, id: \.rawValue) { icon in icon.menuImage.frame(width: 16, height: 16) }
            }
            .foregroundStyle(.primary).padding(8)
            .background(dark ? Color(white: 0.1) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            for (index, icon) in icons.enumerated() {
                XCTAssertTrue(icon.makeMenuTemplateImage().isTemplate)
                var contrastingPixels = 0
                for x in (16 + index * 48)..<(48 + index * 48) {
                    for y in 16..<48 {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        if dark ? color.redComponent > 0.7 : color.redComponent < 0.3 { contrastingPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(contrastingPixels, 5, "\(icon) must contrast with its menu background")
            }
            let directory = URL(fileURLWithPath: "/tmp/codexbar-ui-v2-review", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                directory.appendingPathComponent(dark ? "menu-icons-dark.png" : "menu-icons-light.png"))
        }
    }

    func testCompactRowsKeepTheirHeightWhenSwitchActionAppears() throws {
        for hovered in [false, true] {
            let row = HStack {
                Text("deepseek-v4-pro").font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                Spacer()
                MenuPanelHoverSwitchButton(isHovered: hovered, action: {})
            }
            .frame(width: 368, height: MenuPanelLayout.compactRowHeight)
            .foregroundColor(.black).background(Color.white)
            .accentColor(.purple)
            let host = NSHostingView(rootView: row)
            host.frame.size = host.fittingSize
            XCTAssertEqual(host.fittingSize.height, 24, accuracy: 0.5)
            // Pure SwiftUI rows can be rendered directly, without AppKit's partial layer cache.
            let renderer = ImageRenderer(content: row.environment(\.colorScheme, .light))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: "/tmp/codexbar-ui-v2-review", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(hovered ? "switch-row-hover.png" : "switch-row-idle.png"))
        }
    }

    func testUnknownQuotaIsNotPresentedAsUnlimitedOrZero() {
        XCTAssertEqual(MenuPanelQuotaPresentation.value(period: CodexBarProviderUsagePeriod(resetAt: Date()), mode: .remaining, unit: "%"), "—")
        XCTAssertEqual(MenuPanelQuotaPresentation.value(period: CodexBarProviderUsagePeriod(used: 100, limit: 100), mode: .remaining, unit: "%"), "0%")
        let unlimited = MenuPanelQuotaPresentation.value(period: CodexBarProviderUsagePeriod(limit: 0), mode: .remaining, unit: "%")
        XCTAssertEqual(unlimited, L.zh ? "不限" : "Unlimited")
    }

    func testThreeQuotaWindowsKeepTheirHeightAtNarrowPanelWidth() throws {
        let originalLanguage = L.languageOverride
        defer { L.languageOverride = originalLanguage }
        for chinese in [true, false] {
            L.languageOverride = chinese
            let quota = MenuPanelProviderQuota(data: PanelCatalogStub.usage.providerUsageData,
                mode: .remaining, now: Date())
                .frame(width: MenuBarStatusItemIdentity.popoverContentWidth - 64)
            let host = NSHostingView(rootView: quota)
            host.frame.size = host.fittingSize
            XCTAssertLessThanOrEqual(host.fittingSize.height, 30,
                "Narrowing the panel must not turn three quota columns into three rows")
            try capture(host, name: chinese ? "quota-narrow-zh" : "quota-narrow-en")
        }
    }

    func testProviderContentsKeepEveryKeyAndModelAcrossSelectionChanges() throws {
        let first = CodexBarProviderAccount(id: "key-a", kind: .apiKey, label: "First", apiKey: "fixture-a",
            openRouterSelection: CodexBarOpenRouterSelection(selectedModelID: "openai/gpt-5.4",
                pinnedModelIDs: ["openai/gpt-5.4", "deepseek/deepseek-v4-pro"]))
        let second = CodexBarProviderAccount(id: "key-b", kind: .apiKey, label: "Second", apiKey: "fixture-b",
            openRouterSelection: CodexBarOpenRouterSelection(selectedModelID: "openai/gpt-5.4",
                pinnedModelIDs: ["openai/gpt-5.4"]))
        let provider = CodexBarProvider(id: "router", kind: .openRouter, label: "OpenRouter", accounts: [first, second])
        let target = MenuPanelTarget(providerID: provider.id, accountID: first.id, modelID: "openai/gpt-5.4")
        XCTAssertEqual(Set(MenuPanelPresentation.models(for: provider, account: first, target: target).map(\.id)),
            Set(["openai/gpt-5.4", "deepseek/deepseek-v4-pro"]))
        let otherKey = MenuPanelTarget(providerID: provider.id, accountID: second.id, modelID: "openai/gpt-5.4")
        XCTAssertEqual(MenuPanelPresentation.models(for: provider, account: first, target: target),
            MenuPanelPresentation.models(for: provider, account: first, target: otherKey))
        XCTAssertFalse(otherKey.matches(providerID: provider.id, accountID: first.id, modelID: "openai/gpt-5.4"))
        let unpinned = MenuPanelTarget(providerID: provider.id, accountID: second.id, modelID: "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(MenuPanelPresentation.models(for: provider, account: second, target: unpinned).map(\.id),
            ["openai/gpt-5.4", "anthropic/claude-sonnet-4.6"])
        let actions = MenuPanelProviderActions(addAccount: {}, editProvider: {}, deleteProvider: {}, editAccount: { _ in }, deleteAccount: { _ in })
        for embedded in [false, true] {
            let root = MenuPanelProviderCard(provider: provider, accounts: provider.accounts, activeTarget: otherKey,
                embedded: embedded, usageDisplayMode: .remaining, now: Date(), onActivate: { _, _ in }, actions: actions)
                .padding(16).frame(width: 368).accentColor(.purple)
                .background(Color.white).environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: root)
            host.frame.size = host.fittingSize
            try capture(host, name: embedded ? "provider-container-active" : "provider-container-available")
        }
    }

    func testLargeActiveProviderKeepsAllModelsInsideLockedViewport() throws {
        var config = fixtureConfig(mode: .hybridProvider)
        config.openAI.modelRoutingStyle = .follow
        let index = config.providers.firstIndex { $0.id == "models" }!
        config.providers[index].accounts[0].thirdPartyModelSelection?.pinnedModelIDs =
            (0..<20).map { "deepseek/model-\($0)" }
        try writeConfig(config)
        let store = TokenStore(syncService: PanelSyncStub(), openAIAccountGatewayService: PanelOpenAIGatewayStub(),
            openRouterGatewayService: PanelRouterGatewayStub(), openRouterModelCatalogService: PanelCatalogStub(),
            openCodeModelCatalogService: PanelCatalogStub(), openCodeUsageService: PanelCatalogStub(), codexRunningProcessIDs: { [] })
        let root = MenuBarView(versionDisplay: "2.0.0 (Build 298)")
            .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
                    .environment(\.menuPanelLogoBundle, logoBundle)
            .environment(\.colorScheme, .light).background(Color.white)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 520)
        try capture(host, name: "active-provider-long-models")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        let activeScroll = try XCTUnwrap(scrollViews(host).first { ($0.documentView?.frame.height ?? 0) > 500 })
        XCTAssertLessThanOrEqual(activeScroll.frame.height, 208.5)
        XCTAssertGreaterThan(activeScroll.documentView!.frame.height, activeScroll.frame.height)
        XCTAssertEqual(host.fittingSize.height, 520, accuracy: 1)
    }

    func testRenderPanelModesAndThemesWithIsolatedData() throws {
        let originalLanguage = L.languageOverride
        L.languageOverride = true
        defer { L.languageOverride = originalLanguage }
        for mode in CodexBarOpenAIAccountUsageMode.allCases {
            try writeConfig(fixtureConfig(mode: mode))
            let store = TokenStore(syncService: PanelSyncStub(), openAIAccountGatewayService: PanelOpenAIGatewayStub(), openRouterGatewayService: PanelRouterGatewayStub(), openRouterModelCatalogService: PanelCatalogStub(), openCodeModelCatalogService: PanelCatalogStub(), openCodeUsageService: PanelCatalogStub(), codexRunningProcessIDs: { [] })
            for dark in [false, true] {
                let root = MenuBarView(measuresNaturalHeight: true, versionDisplay: "2.0.0 (Build 298)")
                    .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
                    .environment(\.menuPanelLogoBundle, logoBundle)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
                let fitting = host.fittingSize
                XCTAssertEqual(fitting.width, 400, accuracy: 1)
                XCTAssertGreaterThan(fitting.height, 200)
                host.frame.size = NSSize(width: 400, height: fitting.height)
                host.layoutSubtreeIfNeeded()
                try capture(host, name: "\(mode.rawValue)-\(dark ? "dark" : "light")")
                if mode == .switchAccount && !dark {
                    NotificationCenter.default.post(name: .openAILoginDidFail, object: nil,
                        userInfo: ["message": "示例错误：操作未完成"])
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    host.frame.size = host.fittingSize
                    try capture(host, name: "switch-light-notice")
                }
            }
        }
    }

    func testEmptyAndLongListsStayWithinLockedViewport() throws {
        for empty in [true, false] {
            var config = empty ? CodexBarConfig() : fixtureConfig(mode: .switchAccount)
            if !empty {
                for index in 0..<20 {
                    config.providers.append(CodexBarProvider(id: "extra-\(index)", kind: .openAICompatible,
                        label: "长名称 Provider \(index) with a deliberately long title", accounts: [
                            CodexBarProviderAccount(id: "extra-key-\(index)", kind: .apiKey, label: "Long key label \(index)", apiKey: "fixture")]))
                }
            }
            try writeConfig(config)
            let store = TokenStore(syncService: PanelSyncStub(), openAIAccountGatewayService: PanelOpenAIGatewayStub(), openRouterGatewayService: PanelRouterGatewayStub(), openRouterModelCatalogService: PanelCatalogStub(), openCodeModelCatalogService: PanelCatalogStub(), openCodeUsageService: PanelCatalogStub(), codexRunningProcessIDs: { [] })
            let host = NSHostingView(rootView: MenuBarView(versionDisplay: "2.0.0 (Build 298)")
                .environmentObject(store).environmentObject(OAuthManager()).environmentObject(UpdateCoordinator())
                    .environment(\.menuPanelLogoBundle, logoBundle))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 520)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            XCTAssertEqual(host.fittingSize.height, 520, accuracy: 1)
            try capture(host, name: empty ? "empty" : "long-list")
            if !empty {
                let scrollView = try XCTUnwrap(descendantScrollView(host))
                XCTAssertTrue(scrollView.hasVerticalScroller)
                XCTAssertGreaterThan(scrollView.documentView!.frame.height, scrollView.contentView.frame.height)
                XCTAssertLessThan(scrollView.frame.height, 520)
                XCTAssertLessThanOrEqual(scrollView.documentView!.frame.width, scrollView.contentView.frame.width + 1,
                    "Document \(scrollView.documentView!.frame), clip frame \(scrollView.contentView.frame), clip bounds \(scrollView.contentView.bounds)")
            }
        }
    }

    func testRenderQuotaEdgeStates() throws {
        let now = Date()
        let unknown = CodexBarProviderUsageData(unit: "%", today: CodexBarProviderUsagePeriod(resetAt: now.addingTimeInterval(3600)))
        let quotaHost = NSHostingView(rootView: MenuPanelProviderQuota(data: unknown, mode: .remaining, now: now).padding(16).frame(width: 368))
        quotaHost.frame.size = quotaHost.fittingSize
        try capture(quotaHost, name: "unknown-quota")
    }

    private func descendantScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.descendantScrollView($0) }.first
    }

    private func capture(_ host: NSView, name: String) throws {
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/codexbar-ui-v2-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fixtureConfig(mode: CodexBarOpenAIAccountUsageMode) -> CodexBarConfig {
        let now = Date()
        let oauth = CodexBarProviderAccount(id: "oauth", kind: .oauthTokens, label: "Fixture", email: "star_knight@outlook.com", openAIAccountId: "oauth", accessToken: "fixture", refreshToken: "fixture", idToken: "fixture", planType: "plus", primaryUsedPercent: 7, secondaryUsedPercent: 7, primaryResetAt: now.addingTimeInterval(18000), secondaryResetAt: now.addingTimeInterval(560000), primaryLimitWindowSeconds: 18000, secondaryLimitWindowSeconds: 604800, lastChecked: now)
        let relay = CodexBarProviderAccount(id: "relay-key", kind: .apiKey, label: "Star", apiKey: "sk-fixture-12345678")
        let modelKey = CodexBarProviderAccount(id: "model-key", kind: .apiKey, label: "Default", apiKey: "fixture", thirdPartyModelSelection: CodexBarOpenRouterSelection(selectedModelID: "deepseek-v4-pro", pinnedModelIDs: ["deepseek-v4-pro", "deepseek-v4.1-flash"]))
        let usage = PanelCatalogStub.usage.providerUsageData
        let modelProvider = CodexBarProvider(id: "models", kind: .openAICompatible, label: "OpenCode Go", thirdPartyModelProvider: .openCode, selectedModelID: "deepseek-v4-pro", pinnedModelIDs: ["deepseek-v4-pro", "deepseek-v4.1-flash"], activeAccountId: modelKey.id, usageState: CodexBarProviderUsageState(data: usage, lastUpdatedAt: now), accounts: [modelKey])
        var config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: mode == .hybridProvider ? "models" : "openai", accountId: mode == .hybridProvider ? modelKey.id : oauth.id),
            providers: [CodexBarProvider(id: "openai", kind: .openAIOAuth, label: "OpenAI", activeAccountId: oauth.id, accounts: [oauth]), CodexBarProvider(id: "relay", kind: .openAICompatible, label: "Input", baseURL: "https://example.invalid/v1", activeAccountId: relay.id, accounts: [relay]), modelProvider])
        config.openAI.accountUsageMode = mode
        config.openAI.usageDisplayMode = .remaining
        return config
    }
}

private final class PanelSyncStub: CodexSynchronizing {
    func synchronize(config: CodexBarConfig) throws {}
}

private final class PanelOpenAIGatewayStub: OpenAIAccountGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(accounts: [TokenAccount], accountUsageMode: CodexBarOpenAIAccountUsageMode, routeTarget: OpenAIAccountGatewayRouteTarget) {}
    func currentRoutedAccountID() -> String? { nil }
}

private final class PanelRouterGatewayStub: OpenRouterGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(provider: CodexBarProvider?, isActiveProvider: Bool) {}
}

private struct PanelCatalogStub: OpenRouterModelCatalogFetching, OpenCodeModelCatalogFetching, OpenCodeUsageFetching {
    func fetchCatalog(apiKey: String) async throws -> OpenRouterModelCatalogSnapshot { throw URLError(.notConnectedToInternet) }
    func fetchCatalog(plan: CodexBarOpenCodePlan, apiKey: String) async throws -> OpenCodeModelCatalogSnapshot { throw URLError(.notConnectedToInternet) }
    func loadCachedCatalog(plan: CodexBarOpenCodePlan) -> OpenCodeModelCatalogSnapshot? { nil }
    static var usage: OpenCodeUsageSnapshot {
        let now = Date()
        return OpenCodeUsageSnapshot(rolling: OpenCodeUsageWindow(status: "ok", percent: 0, resetsAt: now.addingTimeInterval(18000)), weekly: OpenCodeUsageWindow(status: "ok", percent: 0, resetsAt: now.addingTimeInterval(560000)), monthly: OpenCodeUsageWindow(status: "ok", percent: 49, resetsAt: now.addingTimeInterval(2400000)), fetchedAt: now)
    }
    func fetchGoUsage(apiKey: String) async throws -> OpenCodeUsageSnapshot { Self.usage }
}
