import SwiftUI

/// Shared by visible More buttons and card context menus.
struct MenuPanelAction: View {
    let title: String
    let icon: Hugeicons
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label { Text(title) } icon: { icon.menuImage }
        }
        // Menu items use system styling; toolbar branding must not rasterize their template icons.
        .tint(nil)
        .accentColor(nil)
    }
}

struct MenuPanelProviderActions {
    let addAccount: () -> Void
    let editProvider: () -> Void
    let deleteProvider: () -> Void
    let editAccount: (CodexBarProviderAccount) -> Void
    let deleteAccount: (CodexBarProviderAccount) -> Void
}

struct MenuPanelProviderMenu: View {
    let provider: CodexBarProvider
    let accounts: [CodexBarProviderAccount]
    let actions: MenuPanelProviderActions

    var body: some View {
        MenuPanelAction(title: L.zh ? "新增 Key" : "Add Key", icon: .addSquare, action: actions.addAccount)
        if provider.kind != .openRouter {
            MenuPanelAction(title: "\(L.editBtn) \(provider.displayName)", icon: .edit02, action: actions.editProvider)
        }
        if accounts.count == 1, let account = accounts.first {
            MenuPanelProviderAccountMenu(account: account, actions: actions)
        } else {
            ForEach(accounts) { account in
                Menu(account.label) { MenuPanelProviderAccountMenu(account: account, actions: actions) }
            }
        }
        Divider()
        MenuPanelAction(title: "\(L.deleteBtn) \(provider.displayName)", icon: .delete, role: .destructive, action: actions.deleteProvider)
    }
}

struct MenuPanelProviderAccountMenu: View {
    let account: CodexBarProviderAccount
    let actions: MenuPanelProviderActions

    var body: some View {
        MenuPanelAction(title: "\(L.editBtn) \(account.label)", icon: .edit02) { actions.editAccount(account) }
        MenuPanelAction(title: "\(L.deleteBtn) \(account.label)", icon: .delete, role: .destructive) { actions.deleteAccount(account) }
    }
}

struct MenuPanelOAuthMenu: View {
    let label: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onReauth: () -> Void
    var onExport: (() -> Void)? = nil
    let onDelete: () -> Void

    var body: some View {
        MenuPanelAction(title: "\(L.refreshUsage) \(label)", icon: .refresh04, action: onRefresh).disabled(isRefreshing)
        MenuPanelAction(title: "\(L.reauth) \(label)", icon: .refresh04, action: onReauth)
        if let onExport {
            MenuPanelAction(title: L.zh ? "导出 \(label)" : "Export \(label)", icon: .upload, action: onExport)
        }
        Divider()
        MenuPanelAction(title: "\(L.deleteBtn) \(label)", icon: .delete, role: .destructive, action: onDelete)
    }
}
