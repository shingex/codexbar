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
        CodexIntegrationToggle(enabled: Binding(
            get: { self.store.config.openAI.modelRoutingEnabled },
            set: { self.setCodexIntegrationFromPanel($0) }
        ))
    }

    @ViewBuilder
    private var openAISwitchTabPanel: some View {
        VStack(alignment: .leading, spacing: self.panelSectionSpacing) {

            if store.accounts.isEmpty {
                EmptyView()
            } else if store.config.activeProvider()?.kind != .openAIOAuth || store.accounts.contains(where: { $0.id != panelTarget?.accountID }) {
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
            Text(L.zh ? "在 Codex 中使用 CodexBar" : "Use CodexBar in Codex")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle(L.zh ? "在 Codex 中使用 CodexBar" : "Use CodexBar in Codex", isOn: self.$enabled)
                .labelsHidden().toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
        .menuPanelHoverChrome(cornerRadius: 8, hoverOpacity: 0.07)
        .accessibilityIdentifier("codexbar.integration-toggle")
    }
}
