import SwiftUI

extension MenuBarView {
    func updateAvailableBanner(availability: AppUpdateAvailability) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L.menuUpdateAvailableTitle(availability.release.version))
                    .font(.system(size: 11, weight: .medium))
                Text(L.menuUpdateAvailableSubtitle(availability.currentVersion, availability.release.version))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(L.menuUpdateAction) {
                Task { await self.updateCoordinator.handleToolbarAction() }
            }
            .disabled(self.updateCoordinator.isChecking)
            .menuPanelHoverChrome(cornerRadius: 6)
        }
        .padding(.horizontal, self.menuHorizontalInset)
        .padding(.vertical, self.blockVerticalInset)
    }

    private func openAIAvailabilityBadge(title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(availableCount > 0 ? Color.green.opacity(0.10) : Color.red.opacity(0.10))
            .foregroundColor(availableCount > 0 ? Color.green.opacity(0.82) : Color.red.opacity(0.82))
            .cornerRadius(4)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: self.sectionCountSlotWidth, alignment: .trailing)
    }

    func openAISectionLabel<Actions: View>(
        _ title: String,
        count: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let count {
                Text(count)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: self.sectionCountSlotWidth, alignment: .trailing)
            }

            actions()
        }
    }

    func openAISectionLabel(_ title: String, count: String? = nil) -> some View {
        self.openAISectionLabel(title, count: count) {
            EmptyView()
        }
    }

    var openAIAccountsSectionLabel: some View {
        HStack(spacing: 6) {
            Text("OpenAI")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let openAIAvailabilityBadgeTitle {
                self.openAIAvailabilityBadge(title: openAIAvailabilityBadgeTitle)
            }

            self.openAIAddAccountButton
        }
    }

    private var openAIAddAccountButton: some View {
        Menu {
            Button(L.gettingStartedOpenAIAuthButton) {
                startOAuthLogin()
            }
            Button(L.gettingStartedOpenAIImportButton) {
                importOpenAIAccountsCSV()
            }
        } label: {
            self.sectionAddButtonLabel
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(width: self.openAISectionActionButtonSize, height: self.openAISectionActionButtonSize)
        .accessibilityLabel(L.addOpenAIAccountMenu)
        .accessibilityIdentifier("codexbar.login-openai.toolbar")
        .help(L.addOpenAIAccountMenu)
        .menuPanelHoverChrome(cornerRadius: 6)
    }

    var providerAddButton: some View {
        self.sectionAddButton {
            openAddProviderWindow()
        }
    }

    func openRouterAddButton(provider: CodexBarProvider) -> some View {
        self.sectionAddButton {
            openAddOpenRouterAccountWindow(provider: provider)
        }
    }

    private func sectionAddButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            self.sectionAddButtonLabel
        }
        .buttonStyle(.borderless)
        .buttonStyle(.plain)
        .frame(width: self.sectionActionButtonSize, height: self.sectionActionButtonSize)
        .menuPanelHoverChrome(cornerRadius: 6)
    }

    private var sectionAddButtonLabel: some View {
        MenuPanelSectionAddIcon(size: self.sectionActionButtonSize)
    }

    private var openAISectionActionButtonSize: CGFloat {
        self.sectionActionButtonSize
    }

    private var openAISectionAddButtonLabel: some View {
        MenuPanelSectionAddIcon(
            size: self.openAISectionActionButtonSize,
            fontSize: 12
        )
    }
}
