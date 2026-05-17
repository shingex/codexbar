import SwiftUI

struct CompatibleProviderRowView: View {
    let provider: CodexBarProvider
    let isActiveProvider: Bool
    let activeAccountId: String?
    var useActionTitle: String = L.useBtn
    let onActivate: (CodexBarProviderAccount) -> Void
    let onAddAccount: () -> Void
    let onEditProvider: () -> Void
    let onDeleteAccount: (CodexBarProviderAccount) -> Void
    let onDeleteProvider: () -> Void
    private let primaryActionMinWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActiveProvider ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(provider.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActiveProvider ? .accentColor : .primary)

                Text(provider.hostLabel)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.secondary)
                    .cornerRadius(3)

                if isActiveProvider {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }

                Spacer()

                Button(action: onAddAccount) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }

            ForEach(provider.accounts) { account in
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.system(size: 11, weight: account.id == activeAccountId ? .semibold : .regular))

                    if account.id == activeAccountId {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    Spacer()

                    Text(account.maskedAPIKey)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if account.id != activeAccountId || isActiveProvider == false {
                        Button(useActionTitle) {
                            onActivate(account)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .frame(minWidth: self.primaryActionMinWidth)
                    }
                }
                .padding(.leading, 14)
                .contextMenu {
                    Button(role: .destructive) {
                        onDeleteAccount(account)
                    } label: {
                        Label(L.deleteBtn, systemImage: "trash")
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveProvider ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActiveProvider ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055),
                    lineWidth: 0.6
                )
        }
        .overlay(alignment: .leading) {
            if isActiveProvider {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contextMenu {
            Button {
                onEditProvider()
            } label: {
                Label(L.editBtn, systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDeleteProvider()
            } label: {
                Label(L.deleteBtn, systemImage: "trash")
            }
        }
    }
}
