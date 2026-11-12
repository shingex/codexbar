import SwiftUI
import UniformTypeIdentifiers

/// UI-only composition over the provider's existing account/model/usage accessors.
struct MenuPanelProviderCard: View {
    var browsingOnly: Bool = false
    let provider: CodexBarProvider
    let accounts: [CodexBarProviderAccount]
    let activeTarget: MenuPanelTarget?
    let embedded: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let now: Date
    let onActivate: (CodexBarProviderAccount, String?) -> Void
    let actions: MenuPanelProviderActions

    private var isModelProvider: Bool {
        provider.usesAPIKeyAuth
    }

    private func options(_ account: CodexBarProviderAccount) -> [CodexBarOpenRouterModel] {
        MenuPanelPresentation.models(for: provider, account: account, target: activeTarget)
    }

    private func isCurrent(_ account: CodexBarProviderAccount, modelID: String? = nil) -> Bool {
        !browsingOnly && activeTarget?.matches(providerID: provider.id, accountID: account.id, modelID: modelID) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let plan = provider.effectiveOpenCodePlan?.title, plan != provider.displayName {
                    Text(plan).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                if provider.isOpenCodeProvider, accounts.count == 1, let account = accounts.first {
                    Text(account.label).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !embedded {
                    Menu { managementMenu } label: { MenuPanelMoreLabel() }
                        .tint(.primary).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().menuPanelIconControl()
                        .help(L.zh ? "服务操作" : "Provider actions")
                }
            }

            if accounts.isEmpty {
                Button(L.addProviderAccountTitle, action: actions.addAccount)
                    .buttonStyle(.borderless).menuPanelHoverChrome()
            }
            ForEach(accounts) { account in
                accountContent(account)
            }
        }
        .padding(embedded ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if !embedded { MenuPanelCardSurface() } }
        .contentShape(RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius, style: .continuous))
        .contextMenu { managementMenu }
    }

    @ViewBuilder
    private func accountContent(_ account: CodexBarProviderAccount) -> some View {
        if !provider.isOpenCodeProvider || accounts.count > 1 {
            MenuPanelSwitchRow(showsSwitch: !browsingOnly && !isModelProvider, isCurrent: !isModelProvider && isCurrent(account), action: { if !browsingOnly { onActivate(account, nil) } }) {
                Text(account.label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1).truncationMode(.middle)
                if !provider.isOpenCodeProvider {
                    Text(account.maskedAPIKey)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }

        if let error = accountError(account) {
            Text(error).font(.caption).foregroundColor(.orange).lineLimit(2)
        }
        if let data = usageData(account) {
            if data.isValid == false {
                Text(L.zh ? "额度暂不可用" : "Usage unavailable").font(.caption).foregroundColor(.orange)
            }
            if let record = sharedRecord(account) {
                Text(L.providerUsageSharedPlan + " · " + record.title).font(.caption2).foregroundColor(.secondary)
            }
            if data.isBalanceOnly {
                Text(ProviderUsageFormat.balanceTitle(for: data) ?? "—")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                MenuPanelProviderQuota(data: data, mode: usageDisplayMode, now: now)
            }
        }

        if isModelProvider {
            let models = options(account)
            VStack(alignment: .leading, spacing: MenuPanelLayout.compactRowSpacing) {
                ForEach(models) { model in
                    MenuPanelSwitchRow(showsSwitch: !browsingOnly, isCurrent: isCurrent(account, modelID: model.id), action: { if !browsingOnly { onActivate(account, model.id) } }) {
                        MenuPanelLogo(source: ModelDisplayIdentityResolver.identity(
                            thirdPartyProvider: .custom, modelID: model.id
                        ).iconSource)
                        .foregroundColor(ModelDisplayIdentityResolver.identity(thirdPartyProvider: .custom, modelID: model.id).providerCode == "DS" ? .blue : .primary)
                        Text(model.id).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle).help(model.id)
                    }
                }
            }
            if !browsingOnly && activeTarget?.providerID == provider.id && activeTarget?.accountID == account.id && activeTarget?.modelID == nil {
                Text(L.zh ? "尚未指定当前模型" : "No current model selected")
                    .font(.caption).foregroundColor(.secondary)
            }
            if options(account).isEmpty {
                HStack {
                    Text(L.openRouterNoModelsSelected).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button(L.openRouterManageModelsAction) { actions.editAccount(account) }
                        .buttonStyle(.borderless).menuPanelHoverChrome()
                }
            }
        }
    }

    private func accountError(_ account: CodexBarProviderAccount) -> String? {
        provider.usageState?.accountSnapshots.first(where: { $0.accountID == account.id })?.lastError
            ?? provider.usageState?.lastError
    }

    private func sharedRecord(_ account: CodexBarProviderAccount) -> ProviderUsageDisplayRecord? {
        ProviderUsageFormat.records(for: provider).first { $0.isSharedPackage && $0.accountIDs.contains(account.id) }
    }

    private func usageData(_ account: CodexBarProviderAccount) -> CodexBarProviderUsageData? {
        if let record = sharedRecord(account) {
            guard accounts.first(where: { record.accountIDs.contains($0.id) })?.id == account.id else { return nil }
            return record.data
        }
        if let snapshot = provider.usageState?.accountSnapshots.first(where: { $0.accountID == account.id }) {
            return snapshot.data
        }
        return provider.accounts.count == 1 ? provider.usageState?.data : nil
    }

    private var managementMenu: some View {
        MenuPanelProviderMenu(provider: provider, accounts: accounts, actions: actions)
    }


}

extension View {
    func menuPanelProviderReorder(
        providerID: String,
        onMove: @escaping @MainActor (String, String) -> Void
    ) -> some View {
        self.onDrag {
            NSItemProvider(object: providerID as NSString)
        } preview: {
            self.frame(width: MenuBarStatusItemIdentity.popoverContentWidth - 32)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius))
        }
        .onDrop(of: [.plainText], isTargeted: nil) { items in
            guard let item = items.first else { return false }
            _ = item.loadObject(ofClass: String.self) { source, _ in
                guard let source else { return }
                Task { @MainActor in onMove(source, providerID) }
            }
            return true
        }
    }
}

struct MenuPanelProviderQuota: View {
    let data: CodexBarProviderUsageData
    let mode: CodexBarUsageDisplayMode
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) { metrics }
    }

    @ViewBuilder
    private var metrics: some View {
        ForEach(ProviderUsageFormat.availableWindows(for: data)) { window in
            let period = data.period(for: window)
            MenuPanelQuotaMetricView(
                label: ProviderUsageFormat.multiWindowLabel(for: window, data: data),
                resetRemark: period.resetAt.map {
                    $0 > now ? $0.timeIntervalSince(now).shortPanelCountdown : (L.zh ? "即将重置" : "Due")
                },
                value: MenuPanelQuotaPresentation.value(period: period, mode: mode, unit: data.unit),
                valueColor: ProviderUsageVisualStyle.warningLevel(for: period) == .normal
                    ? .green : ProviderUsageVisualStyle.progressColor(for: period),
                progressRatio: period.isUnlimited ? nil : period.displayedProgressRatio(mode: mode),
                contentSpacing: ProviderUsageFormat.availableWindows(for: data).count > 2 ? 3 : 6
            )
        }
    }


}

private extension TimeInterval {
    var shortPanelCountdown: String {
        let minutes = max(0, Int(self / 60))
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return L.zh ? "\(days)天\(hours % 24)时" : "\(days)d \(hours % 24)h" }
        return L.zh ? "\(hours)时\(minutes % 60)分" : "\(hours)h \(minutes % 60)m"
    }
}


enum MenuPanelQuotaPresentation {
    static func value(period: CodexBarProviderUsagePeriod, mode: CodexBarUsageDisplayMode, unit: String) -> String {
        if let limit = period.limit, limit <= 0 { return L.zh ? "不限" : "Unlimited" }
        if let ratio = period.displayedRatio(mode: mode) { return "\(Int((ratio * 100).rounded()))%" }
        if let amount = period.displayedAmount(mode: mode) { return ProviderUsageFormat.compactMoney(amount, unit: unit) }
        return "—"
    }
}
