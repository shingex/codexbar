import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var emptyOpenAIAccountsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No OpenAI account added.")
                .font(.system(size: 11, weight: .medium))
            Text("Use the toolbar plus button to add OpenAI OAuth accounts.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, self.blockContentHorizontalInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    var hybridOAuthLoginSection: some View {
        VStack(alignment: .leading, spacing: self.panelRowSpacing) {
            self.openAIAccountsSectionLabel

            if let account = self.store.config.oauthProvider()?.activeAccount?.asTokenAccount(isActive: true) {
                let isCurrentOAuthRequestTarget = self.store.config.activeProvider()?.kind == .openAIOAuth &&
                    self.store.config.openAI.accountUsageMode == .switchAccount
                AccountRowView(
                    account: account,
                    rowState: OpenAIAccountRowState(
                        isNextUseTarget: isCurrentOAuthRequestTarget,
                        runningThreadCount: self.runningThreadSummary.runningThreadCount(for: account.accountId),
                        accountUsageMode: .switchAccount,
                        actionTitle: L.openAIAccountSwitchAction
                    ),
                    isRefreshing: self.isAccountUsageRefreshing(account),
                    usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                    resetRemark: account.headerQuotaRemark(now: now)
                ) {
                    Task {
                        await self.useCurrentOAuthFromHybrid(account)
                    }
                } onRefresh: {
                    Task { await refreshAccount(account, announceResult: true) }
                } onReauth: {
                    reauthAccount(account)
                } onExport: {
                    exportOpenAIAccountCSV(account)
                } onDelete: {
                    confirmDeleteOpenAIAccount(account)
                } onResolveResetCreditAnchor: { view in
                    resolveResetCreditAnchor(accountID: account.accountId, view: view)
                } onResetCreditHoverChange: { hovering in
                    setResetCreditAccountHover(accountID: account.accountId, hovering: hovering)
                }

                Text(L.openAIHybridCurrentOAuthHint)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                self.emptyOpenAIAccountsView
            }
        }
    }

    @ViewBuilder
    var hybridRequestTargetsSection: some View {
        self.compatibleRequestTargetsSection(
            activationMode: .hybridProvider,
            showsEmptyMessage: true
        )
    }

    @ViewBuilder
    func compatibleRequestTargetsSection(
        activationMode: CodexBarOpenAIAccountUsageMode,
        showsEmptyMessage: Bool
    ) -> some View {
        let providerCount = self.visibleCompatibleProviderCount
        let openRouterProvider = self.visibleOpenRouterProvider

        if providerCount > 0 || openRouterProvider != nil || showsEmptyMessage {
            VStack(alignment: .leading, spacing: self.panelRowSpacing) {
                self.openAISectionLabel(L.openAIHybridTargetsTitle, count: "\(providerCount)") {
                    self.providerAddButton
                }

                if providerCount == 0 && openRouterProvider == nil {
                    Text(L.openAIHybridNoTargets)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, self.blockContentHorizontalInset)
                        .padding(.vertical, 8)
                } else {
                    if store.customProviders.isEmpty == false {
                        self.openAISectionLabel("OpenAI中转", count: "\(store.customProviders.count)")
                        ForEach(store.customProviders) { provider in
                            self.compatibleProviderRow(provider, activationMode: activationMode)
                        }
                    }

                    if store.thirdPartyModelProviders.isEmpty == false {
                        self.openAISectionLabel("第三方模型", count: "\(store.thirdPartyModelProviders.count)")
                        ForEach(store.thirdPartyModelProviders) { provider in
                            self.thirdPartyProviderGroup(provider, activationMode: activationMode)
                        }
                    }
                }

                if let provider = openRouterProvider {
                    self.openAISectionLabel("OpenRouter", count: "\(provider.accounts.count)") {
                        self.openRouterAddButton(provider: provider)
                    }

                    ForEach(provider.accounts) { account in
                        OpenRouterKeyRowView(
                            provider: provider,
                            account: account,
                            isActiveProvider: store.activeProvider?.id == provider.id &&
                                store.config.openAI.accountUsageMode == activationMode,
                            activeAccountId: store.config.active.providerId == provider.id ? store.config.active.accountId : provider.activeAccountId,
                            usageData: provider.usageState?.data,
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                            useActionTitle: activationMode == .hybridProvider ? L.providerUseAction : L.openAIAccountSwitchAction
                        ) {
                            Task {
                                await activateOpenRouterProvider(
                                    accountID: account.id,
                                    accountUsageMode: activationMode
                                )
                            }
                        } onSelectModel: { modelID in
                            Task {
                                await selectOpenRouterModel(
                                    modelID,
                                    accountID: account.id,
                                    accountUsageMode: activationMode
                                )
                            }
                        } onEditModel: {
                            openEditOpenRouterWindow(provider: provider, account: account)
                        } onDeleteAccount: {
                            confirmDeleteOpenRouterAccount(account)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compatibleProviderRow(
        _ provider: CodexBarProvider,
        activationMode: CodexBarOpenAIAccountUsageMode
    ) -> some View {
        CompatibleProviderRowView(
            provider: provider,
            isActiveProvider: store.activeProvider?.id == provider.id &&
                store.config.openAI.accountUsageMode == activationMode,
            activeAccountId: provider.activeAccountId,
            usageData: provider.usageState?.data,
            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
            useActionTitle: activationMode == .hybridProvider ? L.providerUseAction : L.openAIAccountSwitchAction
        ) { account in
            Task {
                await activateCompatibleProvider(
                    providerID: provider.id,
                    accountID: account.id,
                    accountUsageMode: activationMode
                )
            }
        } onAddAccount: {
            openAddProviderAccountWindow(provider: provider)
        } onEditProvider: {
            openEditProviderWindow(provider: provider)
        } onEditAccount: { account in
            openEditProviderAccountWindow(provider: provider, account: account)
        } onDeleteAccount: { account in
            confirmDeleteCompatibleAccount(provider: provider, account: account)
        } onDeleteProvider: {
            confirmDeleteProvider(provider: provider)
        }
    }

    private func thirdPartyProviderGroup(
        _ provider: CodexBarProvider,
        activationMode: CodexBarOpenAIAccountUsageMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(provider.accounts) { account in
                ThirdPartyModelKeyRowView(
                    provider: provider,
                    account: account,
                    isActiveProvider: store.activeProvider?.id == provider.id &&
                        store.config.openAI.accountUsageMode == activationMode,
                    activeAccountId: store.config.active.providerId == provider.id ? store.config.active.accountId : provider.activeAccountId,
                    usageData: provider.usageState?.data,
                    usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                    useActionTitle: activationMode == .hybridProvider ? L.providerUseAction : L.openAIAccountSwitchAction,
                    showsKeyDigest: false
                ) {
                    Task {
                        await activateCompatibleProvider(
                            providerID: provider.id,
                            accountID: account.id,
                            modelID: provider.thirdPartyEffectiveModelID(forAccountID: account.id),
                            accountUsageMode: activationMode
                        )
                    }
                } onSelectModel: { modelID in
                    Task {
                        await selectThirdPartyModel(
                            modelID,
                            providerID: provider.id,
                            accountID: account.id,
                            accountUsageMode: activationMode
                        )
                    }
                } onEditAccount: {
                    openEditProviderAccountWindow(provider: provider, account: account)
                } onDeleteAccount: {
                    confirmDeleteCompatibleAccount(provider: provider, account: account)
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    func openAIAccountGroupsView(
        _ groups: [OpenAIAccountGroup],
        actionMode: CodexBarOpenAIAccountUsageMode
    ) -> some View {
        VStack(alignment: .leading, spacing: self.panelRowSpacing) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: self.panelRowSpacing) {
                    ForEach(group.accounts) { account in
                        let rowState = OpenAIAccountPresentation.rowState(
                            for: account,
                            summary: self.runningThreadSummary,
                            accountUsageMode: actionMode
                        )
                        AccountRowView(
                            account: account,
                            rowState: rowState,
                            isRefreshing: self.isAccountUsageRefreshing(account),
                            usageDisplayMode: self.store.config.openAI.usageDisplayMode,
                            resetRemark: account.headerQuotaRemark(now: now)
                        ) {
                            Task {
                                await activateAccount(account)
                            }
                        } onRefresh: {
                            Task { await refreshAccount(account, announceResult: true) }
                        } onReauth: {
                            reauthAccount(account)
                        } onExport: {
                            exportOpenAIAccountCSV(account)
                        } onDelete: {
                            confirmDeleteOpenAIAccount(account)
                        } onResolveResetCreditAnchor: { view in
                            resolveResetCreditAnchor(accountID: account.accountId, view: view)
                        } onResetCreditHoverChange: { hovering in
                            setResetCreditAccountHover(accountID: account.accountId, hovering: hovering)
                        }
                    }
                }
            }
        }
    }
}
