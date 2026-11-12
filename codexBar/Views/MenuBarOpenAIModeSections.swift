import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var openAIModeTabsSection: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {
            self.openAIModeSelectedTabPanel
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

    }

    private var openAIModeSelectedTabPanel: some View {
        self.openAISwitchTabPanel
    }

    var codexIntegrationControl: some View {
        VStack(alignment: .leading, spacing: 6) {
        CodexIntegrationToggle(enabled: Binding(
            get: { self.store.config.openAI.modelRoutingEnabled },
            set: { self.setCodexIntegrationFromPanel($0) }
        ))

        }
    }

    @ViewBuilder
    private var openAISwitchTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {

            let summarizedAccountID = MenuPanelPresentation.oauthAccountIDShownInSummary(config: store.config)
            if store.accounts.contains(where: { $0.accountId != summarizedAccountID }) {
                openAIAccountGroupsView(groupedAccounts, actionMode: store.config.openAI.modelRoutingEnabled ? .hybridProvider : .switchAccount)
                    .zIndex(1)
            }

            self.compatibleRequestTargetsSection(activationMode: store.config.openAI.modelRoutingEnabled ? .hybridProvider : .switchAccount)
        }
    }


}

struct CodexIntegrationToggle: View {
    @Binding var enabled: Bool
    var body: some View {
        HStack {
            Text(L.zh ? (self.enabled ? "已连接Codex" : "连接 Codex") : (self.enabled ? "Connected to Codex" : "Connect to Codex"))
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle(L.zh ? "连接 Codex" : "Connect to Codex", isOn: self.$enabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .fixedSize()
                .menuPanelHoverChrome(cornerRadius: 6, hoverOpacity: 0.12)
                .accessibilityIdentifier("codexbar.integration-toggle")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background { MenuPanelCardSurface() }
    }
}
