import SwiftUI
import UniformTypeIdentifiers

extension MenuBarView {
    func activateCurrentPanelTarget(in mode: CodexBarOpenAIAccountUsageMode) {
        guard let provider = store.config.activeProvider(), let target = panelTarget,
              let account = provider.accounts.first(where: { $0.id == target.accountID }) else { return }
        performPanelSwitch {
            if provider.kind == .openAIOAuth, let oauthAccount = account.asTokenAccount(isActive: true) {
                if mode == .hybridProvider { await useCurrentOAuthFromHybrid(oauthAccount) }
                else { await activateAccount(oauthAccount) }
            } else if provider.kind == .openRouter {
                await activateOpenRouterProvider(accountID: account.id, accountUsageMode: mode)
            } else {
                await activateCompatibleProvider(providerID: provider.id, accountID: account.id, modelID: target.modelID, accountUsageMode: mode)
            }
        }
    }

    var panelTarget: MenuPanelTarget? { MenuPanelTarget.resolve(config: store.config) }
    var panelProvider: CodexBarProvider? {
        if let id = panelTarget?.providerID { return store.config.provider(id: id) }
        return store.config.activeProvider()
    }
    var panelAccount: TokenAccount? {
        if let id = panelTarget?.accountID { return store.oauthAccount(accountID: id) }
        return store.activeAccount()
    }
    var panelResource: MenuPanelResourceID? { MenuPanelPresentation.activeResource(config: store.config) }

    var activePanelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(spacing: 4) {
                    Circle().fill(modeAccentColor).frame(width: 8, height: 8)
                    Text(currentModeContextLabel ?? "").font(.system(size: 12)).foregroundColor(.secondary)
                    if isPanelSwitching { ProgressView().controlSize(.small) }
                }
                Spacer()
                MenuPanelLogo(source: activePanelLogo, size: 48, usesBrandColors: true)
            }
            .frame(height: 24, alignment: .top)

            if let provider = panelProvider {
                if provider.kind == .openAIOAuth, let account = panelAccount {
                    panelAccountRow(account, actionMode: store.config.openAI.accountUsageMode, embedded: true)
                    if store.config.openAI.modelRoutingEnabled {
                        Text(store.config.global.sanitizedDefaultModel)
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else if provider.kind != .openAIOAuth {
                    if measuresNaturalHeight {
                        panelProviderCard(provider, activationMode: store.config.openAI.accountUsageMode, embedded: true)
                    } else {
                        AdaptiveMenuScrollContainer(maxHeight: activeResourceContentHeightLimit) {
                            panelProviderCard(provider, activationMode: store.config.openAI.accountUsageMode, embedded: true)
                                .padding(.trailing, 6)
                        }
                    }
                } else {
                    emptyOpenAIAccountsView
                }
            } else {
                emptyOpenAIAccountsView
            }

            if !store.config.openAI.modelRoutingEnabled && store.config.openAI.accountUsageMode == .hybridProvider,
               let oauthAccount = store.config.oauthProvider()?.activeAccount?.asTokenAccount(isActive: true),
               store.config.activeProvider()?.kind != .openAIOAuth {
                Divider()
                MenuPanelSwitchRow(action: {
                    performPanelSwitch { await useCurrentOAuthFromHybrid(oauthAccount) }
                }) {
                    Text("OAuth · \(MenuPanelPresentation.accountTitle(oauthAccount))")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .disabled(isPanelSwitching)
                .help(L.openAIHybridCurrentOAuthHint)
                .contextMenu { panelOAuthMenu(oauthAccount) }
            }

        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MenuPanelCardSurface(active: true))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .menuPanelHoverChrome(cornerRadius: 16, hoverOpacity: 0.025)
        .contextMenu { activePanelContextMenu }
        .id(panelResource)
        .accessibilityIdentifier("codexbar.active-card")
    }

    private var activePanelLogo: MenuBarStatusItemIconSource? {
        guard let provider = panelProvider else { return nil }
        return panelTarget?.iconSource(for: provider)
    }

    var emptyOpenAIAccountsView: some View {
        Text(L.zh ? "暂无可用账号，请通过顶部加号添加。" : "No account available. Add one using the toolbar plus button.")
            .font(.system(size: 12)).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    func panelAccountRow(_ account: TokenAccount, actionMode: CodexBarOpenAIAccountUsageMode, embedded: Bool = false) -> some View {
        AccountRowView(
            account: account,
            rowState: OpenAIAccountPresentation.rowState(
                for: account, summary: runningThreadSummary, accountUsageMode: actionMode,
                isOAuthProviderActive: store.config.activeProvider()?.kind == .openAIOAuth,
                allowsSwitch: store.accounts.count > 1
            ),
            isRefreshing: isAccountUsageRefreshing(account),
            usageDisplayMode: store.config.openAI.usageDisplayMode,
            resetRemark: account.headerQuotaRemark(now: now), embedded: embedded
        ) {
            performPanelSwitch {
                if actionMode == .hybridProvider { await useCurrentOAuthFromHybrid(account) }
                else { await activateAccount(account) }
            }
        } onRefresh: {
            Task { await refreshAccount(account, announceResult: true) }
        } onReauth: {
            reauthAccount(account)
        } onExport: {
            exportOpenAIAccountCSV(account)
        } onDelete: {
            confirmDeleteOpenAIAccount(account)
        }
        .tint(modeAccentColor).accentColor(modeAccentColor)
    }

    func openAIAccountGroupsView(_ groups: [OpenAIAccountGroup], actionMode: CodexBarOpenAIAccountUsageMode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                ForEach(group.accounts.filter { account in
                    store.config.activeProvider()?.kind != .openAIOAuth || panelTarget?.accountID != account.id
                }) { account in
                    panelAccountRow(account, actionMode: actionMode)
                }
            }
        }
    }

    var availablePanelProviders: [CodexBarProvider] {
        let providers = store.customProviders + store.genericThirdPartyModelProviders + store.openCodeProviders
            + (visibleOpenRouterProvider.map { [$0] } ?? [])
        let order = store.config.openAI.providerDisplayOrder
        return MenuPanelPresentation.availableProviders(providers, activeResource: store.config.openAI.modelRoutingStyle == .catalog ? nil : panelResource)
            .sorted { (order.firstIndex(of: $0.id) ?? Int.max) < (order.firstIndex(of: $1.id) ?? Int.max) }
    }

    func compatibleRequestTargetsSection(activationMode: CodexBarOpenAIAccountUsageMode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(availablePanelProviders) { provider in
                panelProviderCard(provider, activationMode: activationMode)
                    .menuPanelProviderReorder(providerID: provider.id) { source, destination in
                        try? store.moveProvider(source, before: destination)
                    }
            }
        }
    }

    func panelProviderCard(_ provider: CodexBarProvider, activationMode: CodexBarOpenAIAccountUsageMode, embedded: Bool = false) -> some View {
        MenuPanelProviderCard(
            browsingOnly: store.config.openAI.modelRoutingStyle == .catalog,
            provider: provider, accounts: provider.accounts, activeTarget: panelTarget,
            embedded: embedded, usageDisplayMode: store.config.openAI.usageDisplayMode, now: now,
            onActivate: { account, modelID in
                performPanelSwitch {
                    if provider.kind == .openRouter {
                        if let modelID { await selectOpenRouterModel(modelID, accountID: account.id, accountUsageMode: activationMode) }
                        else { await activateOpenRouterProvider(accountID: account.id, accountUsageMode: activationMode) }
                    } else if let modelID {
                        await selectThirdPartyModel(modelID, providerID: provider.id, accountID: account.id, accountUsageMode: activationMode)
                    } else {
                        await activateCompatibleProvider(providerID: provider.id, accountID: account.id, accountUsageMode: activationMode)
                    }
                }
            }, actions: panelProviderActions(provider)
        )
        .disabled(isPanelSwitching)
        .tint(modeAccentColor).accentColor(modeAccentColor)
    }

    func panelProviderActions(_ provider: CodexBarProvider) -> MenuPanelProviderActions {
        MenuPanelProviderActions(addAccount: {
            if provider.kind == .openRouter { openAddOpenRouterAccountWindow(provider: provider) }
            else { openAddProviderAccountWindow(provider: provider) }
        }, editProvider: {
            openEditProviderWindow(provider: provider)
        }, deleteProvider: {
            if provider.kind == .openRouter { confirmDeleteOpenRouterProvider(provider: provider) }
            else { confirmDeleteProvider(provider: provider) }
        }, editAccount: { account in
            if provider.kind == .openRouter { openEditOpenRouterWindow(provider: provider, account: account) }
            else { openEditProviderAccountWindow(provider: provider, account: account) }
        }, deleteAccount: { account in
            if provider.kind == .openRouter { confirmDeleteOpenRouterAccount(account) }
            else { confirmDeleteCompatibleAccount(provider: provider, account: account) }
        })
    }

    func panelOAuthMenu(_ account: TokenAccount) -> some View {
        MenuPanelOAuthMenu(label: MenuPanelPresentation.accountTitle(account), isRefreshing: isAccountUsageRefreshing(account)) {
            Task { await refreshAccount(account, announceResult: true) }
        } onReauth: {
            reauthAccount(account)
        } onExport: {
            exportOpenAIAccountCSV(account)
        } onDelete: {
            confirmDeleteOpenAIAccount(account)
        }
    }

    @ViewBuilder
    private var activePanelContextMenu: some View {
        if let provider = panelProvider {
            if provider.kind == .openAIOAuth, let account = panelAccount {
                panelOAuthMenu(account)
            } else {
                MenuPanelProviderMenu(provider: provider,
                    accounts: provider.accounts,
                    actions: panelProviderActions(provider))
                if !store.config.openAI.modelRoutingEnabled && store.config.openAI.accountUsageMode == .hybridProvider,
                   let account = store.config.oauthProvider()?.activeAccount?.asTokenAccount(isActive: true) {
                    Divider()
                    Menu("OAuth · \(MenuPanelPresentation.accountTitle(account))") { panelOAuthMenu(account) }
                }
            }
        }
    }
}
