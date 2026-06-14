import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var openAIModeTabsSection: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIModeTabsControl

            if let runtimeRouteBanner,
               let actionTitle = runtimeRouteBanner.actionTitle {
                HStack(spacing: 0) {
                    Spacer()

                    Button(actionTitle) {
                        self.clearStaleAggregateStickyIfNeeded()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(runtimeRouteBanner.tone == .warning ? .orange : .secondary)
                    .help(L.aggregateRuntimeClearStaleStickyHint)
                    .menuPanelHoverChrome(cornerRadius: 6)
                }
                .padding(.horizontal, 0)
            }

            if self.selectedModeTab == .aggregateGateway {
                self.openAIModeIntroSlot
            }

            self.openAIModeSelectedTabPanel
                .id(self.selectedModeTab)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: self.store.config.openAI.accountUsageMode) { mode in
            withAnimation(.easeInOut(duration: 0.18)) {
                self.selectedModeTab = mode
            }
        }
    }

    private var openAIModeIntroSlot: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.openAIAggregatePanelTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(L.openAIAggregatePanelHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var openAIModeSelectedTabPanel: some View {
        switch self.selectedModeTab {
        case .switchAccount:
            self.openAISwitchTabPanel
        case .aggregateGateway:
            self.openAIAggregateTabPanel
        case .hybridProvider:
            self.openAIHybridTabPanel
        }
    }

    private var openAIModeTabsControl: some View {
        HStack(spacing: 0) {
            ForEach(CodexBarOpenAIAccountUsageMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.selectedModeTab = mode
                    }
                } label: {
                    Text(mode.menuToggleTitle)
                        .font(.system(size: 10, weight: self.selectedModeTab == mode ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(self.selectedModeTab == mode ? .white : .secondary)
                .menuPanelHoverChrome(
                    cornerRadius: 6,
                    active: self.selectedModeTab == mode,
                    pressedOpacity: 1,
                    activeOpacity: 1
                )
                .accessibilityIdentifier("codexbar.openai-mode-tab.\(mode.rawValue)")

                if mode != CodexBarOpenAIAccountUsageMode.allCases.last {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 14)
                        .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.16))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexbar.openai-mode-picker")
    }

    @ViewBuilder
    private var openAISwitchTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIAccountsSectionLabel

            if store.accounts.isEmpty {
                if self.visibleCompatibleProviderCount == 0 {
                    self.emptyOpenAIAccountsView
                }
            } else {
                openAIAccountGroupsView(groupedAccounts, actionMode: .switchAccount)
            }

            self.compatibleRequestTargetsSection(
                activationMode: .switchAccount,
                showsEmptyMessage: self.visibleCompatibleProviderCount == 0
            )
        }
    }

    @ViewBuilder
    private var openAIAggregateTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIAccountsSectionLabel

            if store.accounts.isEmpty {
                self.emptyOpenAIAccountsView
            } else {
                openAIAccountGroupsView(groupedAccounts, actionMode: .aggregateGateway)
            }

            HStack {
                Spacer()
                Button(
                    self.store.config.openAI.accountUsageMode == .aggregateGateway
                        ? L.openAIAggregateEnabledAction
                        : L.openAIAggregateEnableAction
                ) {
                    Task { await self.setOpenAIAccountUsageMode(.aggregateGateway) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(self.store.config.openAI.accountUsageMode == .aggregateGateway || self.store.accounts.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var openAIHybridTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.hybridOAuthLoginSection
            self.hybridRequestTargetsSection
        }
    }
}
