import SwiftUI

struct CompatibleProviderRowView: View {
    let provider: CodexBarProvider
    let isActiveProvider: Bool
    let activeAccountId: String?
    var usageData: CodexBarProviderUsageData?
    var usageDisplayMode: CodexBarUsageDisplayMode = .used
    var useActionTitle: String = L.useBtn
    let onActivate: (CodexBarProviderAccount) -> Void
    let onAddAccount: () -> Void
    let onEditProvider: () -> Void
    let onEditAccount: (CodexBarProviderAccount) -> Void
    let onDeleteAccount: (CodexBarProviderAccount) -> Void
    let onDeleteProvider: () -> Void
    @State private var isHoveringProvider = false
    @State private var hoveringAccountID: String?
    private let primaryActionWidth = MenuPanelLayout.primaryActionWidth

    private func isCurrentAccount(_ account: CodexBarProviderAccount) -> Bool {
        self.isActiveProvider && account.id == self.activeAccountId
    }

    private func accountRowBackground(accountID: String) -> Color {
        self.hoveringAccountID == accountID ? Color.secondary.opacity(0.08) : Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActiveProvider ? .accentColor : .primary)

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .menuPanelHoverChrome(cornerRadius: 5)
            }

            ForEach(provider.accounts) { account in
                HStack(spacing: 6) {
                    Text(account.maskedAPIKey)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(account.label)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(self.isCurrentAccount(account) ? .primary : .secondary)
                        .cornerRadius(4)

                    Spacer()

                    if self.isCurrentAccount(account) {
                        MenuPanelCurrentIndicator(width: self.primaryActionWidth)
                    } else if self.useActionTitle.isEmpty == false {
                        Button {
                            onActivate(account)
                        } label: {
                            Text(useActionTitle)
                                .frame(maxWidth: .infinity)
                                .frame(height: MenuPanelLayout.primaryActionHeight)
                        }
                        .buttonStyle(MenuPanelPrimaryActionButtonStyle())
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: self.primaryActionWidth, alignment: .center)
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, 4)
                .padding(.bottom, 1)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(self.accountRowBackground(accountID: account.id))
                )
                .onHover { hovering in
                    self.hoveringAccountID = hovering ? account.id : nil
                }
                .contextMenu {
                    let objectName = self.accountContextObject(account)

                    Button {
                        onEditAccount(account)
                    } label: {
                        Label(L.editContextMenuItem(objectName), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        onDeleteAccount(account)
                    } label: {
                        Label(L.deleteContextMenuItem(objectName), systemImage: "trash")
                    }
                }
            }

            if self.isActiveProvider,
               let usageData {
                ProviderUsageInlineProgressView(
                    data: usageData,
                    usageDisplayMode: self.usageDisplayMode,
                    isCompact: true
                )
                    .padding(.top, 0)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActiveProvider
                        ? Color.accentColor.opacity(self.isHoveringProvider ? 0.11 : 0.07)
                        : Color.secondary.opacity(self.isHoveringProvider ? 0.08 : 0.04)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActiveProvider ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055),
                    lineWidth: 0.6
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { self.isHoveringProvider = $0 }
        .contextMenu {
            let objectName = L.providerContextObject(self.provider.label)

            Button {
                onEditProvider()
            } label: {
                Label(L.editContextMenuItem(objectName), systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDeleteProvider()
            } label: {
                Label(L.deleteContextMenuItem(objectName), systemImage: "trash")
            }
        }
    }

    private func accountContextObject(_ account: CodexBarProviderAccount) -> String {
        L.providerAccountContextObject(self.provider.label, account.label)
    }
}
