import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    let account: TokenAccount
    let rowState: OpenAIAccountRowState
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    var resetRemark: String? = nil
    var embedded = false
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    var onExport: (() -> Void)? = nil
    let onDelete: () -> Void

    @State private var isHoveringPlanBadge = false
    @State private var isHovered = false

    private var usageWindows: [UsageWindowDisplay] {
        self.account.usageWindowDisplays(mode: self.usageDisplayMode)
    }

    private var primaryRemainingPercent: Double {
        self.usageWindows.first?.remainingPercent ?? 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if !self.embedded {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }

                self.planBadge

                Text(self.accountTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(self.accountTitle)

                Spacer(minLength: 8)

                if !self.embedded { self.primaryActionSlot }
                if !self.embedded {
                    Menu { self.managementMenu } label: { MenuPanelMoreLabel() }
                        .tint(.primary).menuStyle(.borderlessButton)
                        .menuIndicator(.hidden).fixedSize().menuPanelIconControl()
                        .help(L.zh ? "账号操作" : "Account actions")
                }
            }
            .frame(height: self.embedded ? nil : MenuPanelLayout.compactRowHeight)
            .padding(.trailing, self.embedded ? 60 : 0)

            if account.isBanned || account.tokenExpired {
                Text(account.tokenExpired ? L.reauth : (L.zh ? "账号不可用" : "Account unavailable"))
                    .font(.caption).foregroundColor(.orange)
            }
            if let badge = self.rowState.runningThreadBadgeTitle {
                Text(badge).font(.caption2).foregroundColor(.secondary)
            }
            if self.usageWindows.isEmpty || account.lastChecked == nil {
                Text(L.zh ? "尚未获取额度" : "Usage unavailable").font(.caption).foregroundColor(.secondary)
            } else {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(self.usageWindows.prefix(2)) { window in
                    OpenAIAccountQuotaMetricView(
                        window: window,
                        resetRemark: self.resetRemarkText(for: window.id == self.usageWindows.first?.id ? 0 : 1)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(self.embedded ? 0 : 10)
        .background { if !self.embedded { MenuPanelCardSurface() } }
        .contentShape(RoundedRectangle(cornerRadius: MenuPanelSurface.cornerRadius, style: .continuous))
        .menuPanelHoverRegion { isHovered = $0 }
        .contextMenu { self.managementMenu }
    }

    private var managementMenu: some View {
        MenuPanelOAuthMenu(label: self.accountTitle, isRefreshing: self.isRefreshing,
            onRefresh: self.onRefresh, onReauth: self.onReauth,
            onExport: self.onExport, onDelete: self.onDelete)
    }

    private var accountTitle: String {
        MenuPanelPresentation.accountTitle(self.account)
    }

    @ViewBuilder
    private var primaryActionSlot: some View {
        if self.rowState.isNextUseTarget {
            MenuPanelCurrentIndicator(width: MenuPanelLayout.primaryActionWidth)
        } else if self.account.tokenExpired {
            Button {
                onReauth()
            } label: {
                Text(L.reauth)
                    .frame(maxWidth: .infinity)
                    .frame(height: MenuPanelLayout.primaryActionHeight)
            }
            .buttonStyle(MenuPanelPrimaryActionButtonStyle(tint: .orange))
            .font(.system(size: 10, weight: .medium))
            .frame(width: MenuPanelLayout.primaryActionWidth)
        } else if self.account.isBanned == false,
                  self.rowState.showsUseAction {
            MenuPanelHoverSwitchButton(isHovered: self.isHovered, title: rowState.useActionTitle, action: onActivate)
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
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.15))
        .foregroundColor(Color.accentColor)
        .cornerRadius(3)
        .contentShape(RoundedRectangle(cornerRadius: 3))
        .onHover { isHovering in
            self.isHoveringPlanBadge = isHovering
        }
    }

    private var statusColor: Color {
        if account.isBanned { return .red }
        if account.quotaExhausted { return .orange }
        if self.primaryRemainingPercent <= OpenAIVisualWarningThreshold.criticalRemainingPercent {
            return .red
        }
        if self.primaryRemainingPercent < OpenAIVisualWarningThreshold.warningRemainingPercent {
            return .orange
        }
        return .green
    }

    private func resetRemarkText(for index: Int) -> String? {
        switch index {
        case 0:
            return self.nonEmptyResetRemark(self.resetRemark ?? self.account.primaryCompactResetDescription)
        case 1:
            return self.nonEmptyResetRemark(self.account.secondaryCompactResetDescription)
        default:
            return nil
        }
    }

    private func nonEmptyResetRemark(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

}

struct OpenAIAccountQuotaMetricView: View {
    let window: UsageWindowDisplay
    var resetRemark: String?

    private var displayPercent: Double {
        min(max(self.window.displayPercent, 0), 100)
    }

    private var progressRatio: Double {
        self.displayPercent / 100
    }

    var body: some View {
        MenuPanelQuotaMetricView(
            label: self.window.label,
            resetRemark: self.resetRemark,
            value: "\(Int(self.displayPercent.rounded()))%",
            valueColor: self.metricColor,
            progressRatio: self.progressRatio
        )
    }

    private var metricColor: Color {
        if self.window.usedPercent >= 100 { return .red }
        if self.window.remainingPercent <= OpenAIVisualWarningThreshold.criticalRemainingPercent {
            return .red
        }
        if self.window.remainingPercent < OpenAIVisualWarningThreshold.warningRemainingPercent {
            return .orange
        }
        return .green
    }
}

/// Shared quota typography and alignment for OAuth and provider accounts.
struct MenuPanelQuotaMetricView: View {
    let label: String
    var resetRemark: String?
    let value: String
    let valueColor: Color
    var progressRatio: Double?
    var contentSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: contentSpacing) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let resetRemark {
                    Text(resetRemark)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Text(value)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            if let progressRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [
                            Color.primary.opacity(0.78), Color.primary.opacity(0.64)
                        ], startPoint: .top, endPoint: .bottom))
                            // Keep a nonzero quota visible without changing its numeric value.
                            .frame(width: max(progressRatio > 0 ? 2 : 0, proxy.size.width * progressRatio))
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 6)
            }
        }
        .frame(minWidth: 84, maxWidth: .infinity, alignment: .trailing)
    }
}
