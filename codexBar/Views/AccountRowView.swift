import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    let account: TokenAccount
    let rowState: OpenAIAccountRowState
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    var onExport: (() -> Void)? = nil
    let onDelete: () -> Void

    @State private var isHoveringPlanBadge = false
    @State private var isHoveringRow = false
    private let primaryActionWidth = MenuPanelLayout.primaryActionWidth

    var body: some View {
        HStack(spacing: 6) {
            if self.usesExpandedTeamBadgeHoverLayout == false {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            self.planBadge

            if self.usesExpandedTeamBadgeHoverLayout == false {
                usageSummary

                if let runningThreadBadgeTitle = rowState.runningThreadBadgeTitle {
                    Text(runningThreadBadgeTitle)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }

            }

            Spacer(minLength: self.usesExpandedTeamBadgeHoverLayout ? 0 : 6)

            HStack(spacing: 4) {
                if self.rowState.isNextUseTarget {
                    MenuPanelCurrentIndicator(width: self.primaryActionWidth)
                } else if account.tokenExpired {
                    Button {
                        onReauth()
                    } label: {
                        Text(L.reauth)
                            .frame(maxWidth: .infinity)
                            .frame(height: MenuPanelLayout.primaryActionHeight)
                    }
                    .buttonStyle(MenuPanelPrimaryActionButtonStyle(tint: .orange))
                    .font(.system(size: 10, weight: .medium))
                        .frame(width: self.primaryActionWidth)
                } else if !account.isBanned {
                    Button(action: onRefresh) {
                        Group {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(isRefreshing ? .accentColor : .secondary.opacity(0.82))
                    .disabled(isRefreshing)
                    .menuPanelHoverChrome(cornerRadius: 5)

                    if rowState.showsUseAction {
                        Button {
                            onActivate()
                        } label: {
                            Text(rowState.useActionTitle)
                                .frame(maxWidth: .infinity)
                                .frame(height: MenuPanelLayout.primaryActionHeight)
                        }
                        .buttonStyle(MenuPanelPrimaryActionButtonStyle())
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: self.primaryActionWidth)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(self.effectiveRowBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rowBorderColor, lineWidth: 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { self.isHoveringRow = $0 }
        .contextMenu {
            if let onExport {
                Button {
                    onExport()
                } label: {
                    Label(L.exportContextMenuItem(self.contextObjectName), systemImage: "square.and.arrow.up")
                }
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L.deleteContextMenuItem(self.contextObjectName), systemImage: "trash")
            }
        }
    }

    private var contextObjectName: String {
        let accountLabel = self.account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            self.account.accountId :
            self.account.email
        return L.openAIAccountContextObject(accountLabel)
    }

    @ViewBuilder
    private var usageSummary: some View {
        HStack(spacing: 6) {
            ForEach(Array(account.usageWindowDisplays(mode: self.usageDisplayMode).enumerated()), id: \.offset) { index, window in
                if index > 0 {
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Text(window.label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("\(Int(window.displayPercent))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(usageColor(window))
            }
        }
    }

    private var planBadge: some View {
        Text(
            OpenAIAccountPresentation.planBadgeTitle(
                for: self.account,
                isHovered: self.isHoveringPlanBadge
            )
        )
        .font(.system(size: 9, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .allowsTightening(self.usesExpandedTeamBadgeHoverLayout)
        .minimumScaleFactor(self.usesExpandedTeamBadgeHoverLayout ? 0.85 : 1)
        .layoutPriority(self.usesExpandedTeamBadgeHoverLayout ? 1 : 0)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(planBadgeColor.opacity(0.15))
        .foregroundColor(planBadgeColor)
        .cornerRadius(3)
        .contentShape(RoundedRectangle(cornerRadius: 3))
        .onHover { isHovering in
            self.isHoveringPlanBadge = isHovering
        }
    }

    private var usesExpandedTeamBadgeHoverLayout: Bool {
        OpenAIAccountPresentation.usesExpandedTeamBadgeHoverLayout(
            for: self.account,
            isHovered: self.isHoveringPlanBadge
        )
    }

    private var statusColor: Color {
        if account.isBanned { return .red }
        if account.quotaExhausted { return .orange }
        if account.isBelowVisualWarningThreshold() { return .yellow }
        return .green
    }

    private var rowBackgroundColor: Color {
        if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.07) }
        if account.isBanned { return Color.red.opacity(0.045) }
        if account.quotaExhausted { return Color.orange.opacity(0.05) }
        if account.isBelowVisualWarningThreshold() {
            return Color.yellow.opacity(0.05)
        }
        return Color.secondary.opacity(0.04)
    }

    private var effectiveRowBackgroundColor: Color {
        if self.isHoveringRow {
            if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.11) }
            return Color.secondary.opacity(0.08)
        }
        return self.rowBackgroundColor
    }

    private var rowBorderColor: Color {
        if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.2) }
        if account.isBanned { return Color.red.opacity(0.12) }
        if account.quotaExhausted { return Color.orange.opacity(0.14) }
        if account.isBelowVisualWarningThreshold() {
            return Color.yellow.opacity(0.14)
        }
        return Color.primary.opacity(0.055)
    }

    private var planBadgeColor: Color {
        switch account.planType.lowercased() {
        case "team": return .blue
        case "plus": return .purple
        default: return .gray
        }
    }

    private func usageColor(_ window: UsageWindowDisplay) -> Color {
        if window.usedPercent >= 100 { return .red }
        if window.remainingPercent <= OpenAIVisualWarningThreshold.remainingPercent {
            return .orange
        }

        switch self.usageDisplayMode {
        case .remaining:
            return .green
        case .used:
            if window.usedPercent >= 70 { return .orange }
            return .green
        }
    }
}
