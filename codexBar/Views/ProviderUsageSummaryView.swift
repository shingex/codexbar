import SwiftUI

struct ProviderUsageDisplayRecord: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var isSharedPackage: Bool
    var data: CodexBarProviderUsageData
    var accountIDs: [String]
    var accountCount: Int
    var lastUpdatedAt: Date?
    var lastError: String?
    var rawResponse: String?
}

enum ProviderUsageWarningLevel: Equatable {
    case normal
    case warning
    case critical
}

enum ProviderUsageVisualStyle {
    static func warningLevel(for period: CodexBarProviderUsagePeriod) -> ProviderUsageWarningLevel {
        guard let usageRatio = period.usageRatio else { return .normal }
        if usageRatio >= 1 {
            return .critical
        }
        let remainingPercent = max(0, 1 - usageRatio) * 100
        if remainingPercent <= OpenAIVisualWarningThreshold.criticalRemainingPercent {
            return .critical
        }
        if remainingPercent < OpenAIVisualWarningThreshold.warningRemainingPercent {
            return .warning
        }
        return .normal
    }

    static func progressColor(for period: CodexBarProviderUsagePeriod) -> Color {
        switch self.warningLevel(for: period) {
        case .normal:
            return .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

enum ProviderUsageFormat {
    static func records(for provider: CodexBarProvider) -> [ProviderUsageDisplayRecord] {
        let snapshots = self.snapshots(for: provider)
        guard snapshots.isEmpty == false else { return [] }
        let accountOrder = Dictionary(uniqueKeysWithValues: provider.accounts.enumerated().map { index, account in
            (account.id, index)
        })

        let grouped = Dictionary(grouping: snapshots) { snapshot in
            self.packageKey(for: snapshot.data)
        }

        return grouped.values
            .map { group -> ProviderUsageDisplayRecord in
                if group.count == 1, let snapshot = group.first {
                    return self.record(for: snapshot)
                }

                return self.sharedRecord(for: group, accountOrder: accountOrder)
            }
            .sorted {
                self.accountGroupSortIndex($0, accountOrder: accountOrder) <
                    self.accountGroupSortIndex($1, accountOrder: accountOrder)
            }
    }

    static func money(_ value: Double, unit: String) -> String {
        let prefix = unit.uppercased() == "USD" ? "$ " : "\(unit) "
        return "\(prefix)\(String(format: "%.2f", value))"
    }

    static func compactMoney(_ value: Double, unit: String) -> String {
        let prefix = unit.uppercased() == "USD" ? "$" : "\(unit) "
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return "\(prefix)\(String(format: "%.1fM", value / 1_000_000))"
        }
        if absolute >= 1_000 {
            return "\(prefix)\(String(format: "%.1fK", value / 1_000))"
        }
        return "\(prefix)\(String(format: "%.2f", value))"
    }

    static func title(for window: ProviderUsageWindow) -> String {
        switch window {
        case .today:
            return L.providerUsageDaily
        case .weekly:
            return L.providerUsageWeekly
        case .monthly:
            return L.providerUsageMonthly
        }
    }

    static func displayLabel(for window: ProviderUsageWindow, mode: CodexBarUsageDisplayMode) -> String {
        switch window {
        case .today:
            return mode == .remaining ? L.providerUsageTodayRemaining : L.providerUsageTodayUsed
        case .weekly:
            return mode == .remaining ? L.providerUsageWeeklyRemaining : L.providerUsageWeeklyUsed
        case .monthly:
            return mode == .remaining ? L.providerUsageMonthlyRemaining : L.providerUsageMonthlyUsed
        }
    }

    static func availableWindows(for data: CodexBarProviderUsageData) -> [ProviderUsageWindow] {
        ProviderUsageWindow.allCases.filter { data.period(for: $0).hasAnyValue }
    }

    static func primaryConfiguredWindow(for data: CodexBarProviderUsageData) -> ProviderUsageWindow {
        self.availableWindows(for: data).first ?? .monthly
    }

    static func balanceTitle(for data: CodexBarProviderUsageData) -> String? {
        guard data.isBalanceOnly, let remaining = data.remaining else { return nil }
        let symbol = Self.balanceCurrencyPrefix(for: data.unit)
        return "\(symbol)\(String(format: "%.2f", remaining))"
    }

    private static func balanceCurrencyPrefix(for unit: String) -> String {
        switch unit {
        case "CNY": return "￥"
        case "USD": return "$"
        default:    return "\(unit) "
        }
    }

    static func compactStatusTitle(
        for provider: CodexBarProvider,
        mode: CodexBarUsageDisplayMode
    ) -> String? {
        if let snapshots = provider.usageState?.accountSnapshots,
           snapshots.isEmpty == false {
            guard let activeData = self.activeUsageData(for: provider, snapshots: snapshots) else {
                return nil
            }
            return self.compactStatusTitle(for: activeData, mode: mode)
        }
        guard let data = provider.usageState?.data else {
            return nil
        }
        return self.compactStatusTitle(for: data, mode: mode)
    }

    static func compactStatusTitle(
        for data: CodexBarProviderUsageData,
        mode: CodexBarUsageDisplayMode
    ) -> String? {
        if let balanceTitle = self.balanceTitle(for: data) {
            return balanceTitle
        }
        let window = self.primaryConfiguredWindow(for: data)
        let period = data.period(for: window)
        let amount = period.displayedAmount(mode: mode)
        let percent = period.displayedRatio(mode: mode)

        guard amount != nil || percent != nil else { return nil }

        let amountText = amount.map { self.compactMoney($0, unit: data.unit) } ?? "--"
        if let percent {
            return "\(amountText)/\(String(format: "%.1f%%", percent * 100))"
        }
        return amountText
    }

    private static func snapshots(for provider: CodexBarProvider) -> [CodexBarProviderAccountUsageSnapshot] {
        if let snapshots = provider.usageState?.accountSnapshots,
           snapshots.isEmpty == false {
            return snapshots.compactMap { snapshot in
                guard snapshot.data != nil else { return nil }
                return snapshot
            }
        }
        guard let data = provider.usageState?.data else { return [] }
        return [
            CodexBarProviderAccountUsageSnapshot(
                accountID: provider.activeAccount?.id ?? provider.id,
                accountLabel: provider.activeAccount?.label ?? provider.label,
                maskedAPIKey: provider.activeAccount?.maskedAPIKey ?? "",
                data: data,
                lastUpdatedAt: provider.usageState?.lastUpdatedAt,
                lastError: provider.usageState?.lastError,
                rawResponse: provider.usageState?.rawResponse
            ),
        ]
    }

    private static func activeUsageData(
        for provider: CodexBarProvider,
        snapshots: [CodexBarProviderAccountUsageSnapshot]
    ) -> CodexBarProviderUsageData? {
        if let activeAccountID = provider.activeAccount?.id,
           let data = snapshots.first(where: { $0.accountID == activeAccountID })?.data {
            return data
        }
        if snapshots.count == 1 {
            return snapshots[0].data
        }
        return nil
    }

    private static func record(
        for snapshot: CodexBarProviderAccountUsageSnapshot
    ) -> ProviderUsageDisplayRecord {
        ProviderUsageDisplayRecord(
            id: snapshot.accountID,
            title: snapshot.accountLabel,
            subtitle: snapshot.maskedAPIKey.isEmpty ? nil : snapshot.maskedAPIKey,
            isSharedPackage: false,
            data: snapshot.data ?? CodexBarProviderUsageData(),
            accountIDs: [snapshot.accountID],
            accountCount: 1,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            lastError: snapshot.lastError,
            rawResponse: snapshot.rawResponse
        )
    }

    private static func sharedRecord(
        for group: [CodexBarProviderAccountUsageSnapshot],
        accountOrder: [String: Int]
    ) -> ProviderUsageDisplayRecord {
        let first = group[0]
        let data = first.data ?? CodexBarProviderUsageData()
        let sortedGroup = group.sorted {
            let leftIndex = accountOrder[$0.accountID] ?? Int.max
            let rightIndex = accountOrder[$1.accountID] ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return $0.accountLabel.localizedStandardCompare($1.accountLabel) == .orderedAscending
        }
        return ProviderUsageDisplayRecord(
            id: sortedGroup.map(\.accountID).joined(separator: "|"),
            title: self.accountNamesTitle(for: sortedGroup),
            subtitle: nil,
            isSharedPackage: true,
            data: data,
            accountIDs: sortedGroup.map(\.accountID),
            accountCount: sortedGroup.count,
            lastUpdatedAt: sortedGroup.compactMap(\.lastUpdatedAt).max(),
            lastError: self.mergedError(sortedGroup.compactMap(\.lastError)),
            rawResponse: sortedGroup.map(\.rawResponse).compactMap { $0 }.joined(separator: "\n\n")
        )
    }

    private static func accountNamesTitle(for group: [CodexBarProviderAccountUsageSnapshot]) -> String {
        group.map(\.accountLabel).joined(separator: "/")
    }

    private static func accountGroupSortIndex(
        _ record: ProviderUsageDisplayRecord,
        accountOrder: [String: Int]
    ) -> Int {
        record.accountIDs.compactMap { accountOrder[$0] }.min() ?? Int.max
    }

    private static func packageKey(for data: CodexBarProviderUsageData?) -> String {
        guard let data else { return UUID().uuidString }
        let parts: [String] = [
            data.unit,
            data.planName ?? "",
            data.expiresAt ?? "",
            self.keyNumber(data.today.limit),
            self.keyNumber(data.weekly.limit),
            self.keyNumber(data.monthly.limit),
            data.balanceDetails.map { "\($0.key):\(self.keyNumber($0.amount))" }.joined(separator: ","),
        ]
        return parts.joined(separator: "|")
    }

    private static func keyNumber(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.6f", value)
    }

    private static func mergedError(_ messages: [String]) -> String? {
        guard messages.isEmpty == false else { return nil }
        return Array(Set(messages)).sorted().joined(separator: " · ")
    }
}

struct ProviderUsageInlineProgressView: View {
    let data: CodexBarProviderUsageData
    let usageDisplayMode: CodexBarUsageDisplayMode
    var isCompact = false

    private var window: ProviderUsageWindow {
        ProviderUsageFormat.primaryConfiguredWindow(for: self.data)
    }

    private var period: CodexBarProviderUsagePeriod {
        self.data.period(for: self.window)
    }

    private var valueText: String {
        if self.data.isBalanceOnly, let remaining = self.data.remaining {
            return ProviderUsageFormat.compactMoney(remaining, unit: self.data.unit)
        }
        if let value = self.period.displayedAmount(mode: self.usageDisplayMode) {
            return ProviderUsageFormat.compactMoney(value, unit: self.data.unit)
        }
        if let totalUsed = self.data.totalUsed {
            return ProviderUsageFormat.compactMoney(totalUsed, unit: self.data.unit)
        }
        return "--"
    }

    private var percentText: String? {
        guard self.data.isBalanceOnly == false else { return nil }
        guard let ratio = self.period.displayedRatio(mode: self.usageDisplayMode) else { return nil }
        return String(format: "%.1f%%", ratio * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.isCompact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.data.isBalanceOnly ? L.providerUsageRemaining : ProviderUsageFormat.displayLabel(for: self.window, mode: self.usageDisplayMode))
                    .font(.system(size: self.isCompact ? 9 : 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text(self.valueText)
                    .font(.system(size: self.isCompact ? 10 : 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let percentText {
                    Text(percentText)
                        .font(.system(size: self.isCompact ? 9 : 10, weight: .semibold))
                        .foregroundColor(self.progressColor)
                        .monospacedDigit()
                }
            }

            if self.data.isBalanceOnly == false,
               let progress = self.period.displayedProgressRatio(mode: self.usageDisplayMode),
               self.period.isUnlimited == false {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.14))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(self.progressColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: self.isCompact ? 4 : 5)
            }
        }
    }

    private var progressColor: Color {
        ProviderUsageVisualStyle.progressColor(for: self.period)
    }
}
