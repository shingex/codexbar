import AppKit
import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    let account: TokenAccount
    let rowState: OpenAIAccountRowState
    let isRefreshing: Bool
    let usageDisplayMode: CodexBarUsageDisplayMode
    var resetRemark: String? = nil
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    var onExport: (() -> Void)? = nil
    let onDelete: () -> Void
    var onResolveResetCreditAnchor: ((NSView?) -> Void)? = nil
    var onResetCreditHoverChange: ((Bool) -> Void)? = nil

    @State private var isHoveringPlanBadge = false
    @State private var isHoveringRow = false

    private var usageWindows: [UsageWindowDisplay] {
        self.account.usageWindowDisplays(mode: self.usageDisplayMode)
    }

    private var primaryRemainingPercent: Double {
        self.usageWindows.first?.remainingPercent ?? 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                self.planBadge

                Text(self.accountTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                self.primaryActionSlot
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(self.usageWindows.prefix(2).enumerated()), id: \.offset) { index, window in
                    OpenAIAccountQuotaMetricView(
                        window: window,
                        resetRemark: self.resetRemarkText(for: index)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 9)
        .padding(.bottom, 12)
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .background(self.rowBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rowBorderColor, lineWidth: 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            self.isHoveringRow = hovering
            self.onResetCreditHoverChange?(hovering)
        }
        .onDisappear {
            self.onResetCreditHoverChange?(false)
            self.onResolveResetCreditAnchor?(nil)
        }
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

    private var rowBackground: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(self.effectiveRowBackgroundColor)

            if self.onResolveResetCreditAnchor != nil {
                ViewReferenceReader { view in
                    self.onResolveResetCreditAnchor?(view)
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
        }
    }

    private var accountTitle: String {
        let email = self.account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? self.account.accountId : email
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
            Button {
                onActivate()
            } label: {
                Text(rowState.useActionTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: MenuPanelLayout.primaryActionHeight)
            }
            .buttonStyle(MenuPanelPrimaryActionButtonStyle())
            .font(.system(size: 10, weight: .medium))
            .frame(width: MenuPanelLayout.primaryActionWidth)
        }
    }

    private var contextObjectName: String {
        let accountLabel = self.account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            self.account.accountId :
            self.account.email
        return L.openAIAccountContextObject(accountLabel)
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
        .background(planBadgeColor.opacity(0.15))
        .foregroundColor(planBadgeColor)
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

    private var rowBackgroundColor: Color {
        if self.rowState.isNextUseTarget { return Color.accentColor.opacity(0.07) }
        if account.isBanned { return Color.red.opacity(0.045) }
        if account.quotaExhausted { return Color.orange.opacity(0.05) }
        if self.primaryRemainingPercent <= OpenAIVisualWarningThreshold.criticalRemainingPercent {
            return Color.red.opacity(0.05)
        }
        if self.primaryRemainingPercent < OpenAIVisualWarningThreshold.warningRemainingPercent {
            return Color.orange.opacity(0.05)
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
        if self.primaryRemainingPercent <= OpenAIVisualWarningThreshold.criticalRemainingPercent {
            return Color.red.opacity(0.14)
        }
        if self.primaryRemainingPercent < OpenAIVisualWarningThreshold.warningRemainingPercent {
            return Color.orange.opacity(0.14)
        }
        return Color.primary.opacity(0.055)
    }

    private var planBadgeColor: Color {
        switch account.planType.lowercased() {
        case "team": return .blue
        case "plus": return .purple
        case "pro": return .indigo
        default: return .gray
        }
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

private struct OpenAIAccountQuotaMetricView: View {
    let window: UsageWindowDisplay
    var resetRemark: String?

    private var displayPercent: Double {
        min(max(self.window.displayPercent, 0), 100)
    }

    private var progressRatio: Double {
        self.displayPercent / 100
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.window.label)
                    .font(.system(size: 9))
                    .foregroundColor(.primary)

                if let resetRemark {
                    Text(resetRemark)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Text("\(Int(self.displayPercent.rounded()))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(self.metricColor)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(self.metricColor)
                        .frame(width: max(2, proxy.size.width * self.progressRatio))
                }
            }
            .frame(height: 4)
        }
        .frame(minWidth: 84, maxWidth: .infinity, alignment: .trailing)
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
