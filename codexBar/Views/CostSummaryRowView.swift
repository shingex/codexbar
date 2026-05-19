import SwiftUI

struct CostSummaryRowView: View {
    let summary: LocalCostSummary
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            self.metricBlock(
                title: L.localCostToday,
                cost: summary.todayCostUSD,
                tokens: summary.todayTokens
            )

            self.metricBlock(
                title: L.localCostLast30Days,
                cost: summary.last30DaysCostUSD,
                tokens: summary.last30DaysTokens
            )
        }
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .padding(.vertical, MenuPanelLayout.blockVerticalInset)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(self.isHovering ? 0.12 : 0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(self.isHovering ? 0.10 : 0.0), lineWidth: 0.8)
        }
    }

    private func metricBlock(title: String, cost: Double, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(currency(cost))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(L.localCostTokens(compactTokens(tokens)))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CostDetailsPanelView: View {
    static let panelWidth: CGFloat = 272
    static let shadowPadding: CGFloat = 16

    static var windowWidth: CGFloat {
        self.panelWidth + self.shadowPadding * 2
    }

    static func panelHeight(hasHistory: Bool) -> CGFloat {
        hasHistory ? 304 : 184
    }

    static func windowHeight(hasHistory: Bool) -> CGFloat {
        self.panelHeight(hasHistory: hasHistory) + self.shadowPadding * 2
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int
    }

    private struct MiniBarChart: View {
        let points: [Point]
        let selectedPoint: Point?
        let currency: (Double) -> String
        let compactTokens: (Int) -> String
        let shortDay: (Date) -> String
        @Binding var selectedID: String?

        private let minBarHeight: CGFloat = 6
        private let barSpacing: CGFloat = 4

        var body: some View {
            GeometryReader { geometry in
                let maxCost = max(points.map(\.costUSD).max() ?? 0, 0.01)
                let slotWidth = geometry.size.width / CGFloat(Swift.max(points.count, 1))
                let selectedIndex = selectedPoint.flatMap { selected in
                    points.firstIndex(where: { $0.id == selected.id })
                }

                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(points) { point in
                            let isSelected = selectedPoint?.id == point.id
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.68))
                                .frame(maxWidth: .infinity)
                                .frame(height: self.barHeight(for: point, totalHeight: geometry.size.height, maxCost: maxCost))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                    if let point = selectedPoint,
                       let selectedIndex {
                        self.detailBubble(for: point)
                            .position(
                                x: self.bubbleX(
                                    selectedIndex: selectedIndex,
                                    slotWidth: slotWidth,
                                    chartWidth: geometry.size.width
                                ),
                                y: 24
                            )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard points.isEmpty == false,
                              location.x >= 0,
                              location.x <= geometry.size.width else {
                            selectedID = nil
                            return
                        }

                        let index = min(max(Int(location.x / max(slotWidth, 1)), 0), points.count - 1)
                        selectedID = points[index].id
                    case .ended:
                        selectedID = nil
                    }
                }
            }
            .frame(height: 128)
        }

        private func detailBubble(for point: Point) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(shortDay(point.date)) · \(currency(point.costUSD))")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(L.localCostTokens(compactTokens(point.totalTokens)))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
            .fixedSize()
        }

        private func bubbleX(selectedIndex: Int, slotWidth: CGFloat, chartWidth: CGFloat) -> CGFloat {
            let proposed = (CGFloat(selectedIndex) + 0.5) * slotWidth
            return min(max(proposed, 58), max(chartWidth - 58, 58))
        }

        private func barHeight(for point: Point, totalHeight: CGFloat, maxCost: Double) -> CGFloat {
            guard totalHeight > 0 else { return minBarHeight }
            let usableHeight = max(totalHeight - 4, minBarHeight)
            let ratio = point.costUSD > 0 ? CGFloat(point.costUSD / maxCost) : 0
            return max(minBarHeight, usableHeight * ratio)
        }
    }

    let summary: LocalCostSummary
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    let shortDay: (Date) -> String

    @State private var selectedID: String?

    private var points: [Point] {
        Array(summary.dailyEntries.prefix(30))
            .sorted { $0.date < $1.date }
            .map { entry in
                Point(id: entry.id, date: entry.date, costUSD: entry.costUSD, totalTokens: entry.totalTokens)
            }
    }

    private var selectedPoint: Point? {
        if let selectedID,
           let selected = points.first(where: { $0.id == selectedID }) {
            return selected
        }
        return points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(title: L.localCostToday, cost: summary.todayCostUSD, tokens: summary.todayTokens)
            metricRow(title: L.localCostLast30Days, cost: summary.last30DaysCostUSD, tokens: summary.last30DaysTokens)
            metricRow(title: L.localCostAllTime, cost: summary.lifetimeCostUSD, tokens: summary.lifetimeTokens)

            Divider()

            if points.isEmpty {
                Text(L.localCostNoHistory)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                MiniBarChart(
                    points: points,
                    selectedPoint: selectedPoint,
                    currency: currency,
                    compactTokens: compactTokens,
                    shortDay: shortDay,
                    selectedID: $selectedID
                )

                HStack {
                    if let first = points.first {
                        Text(shortDay(first.date))
                    }

                    Spacer()

                    if let last = points.last {
                        Text(shortDay(last.date))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(
            width: Self.panelWidth,
            height: Self.panelHeight(hasHistory: !points.isEmpty),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(Self.shadowPadding)
        .frame(
            width: Self.windowWidth,
            height: Self.windowHeight(hasHistory: !points.isEmpty),
            alignment: .center
        )
    }

    private func metricRow(title: String, cost: Double, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text(L.localCostTokens(compactTokens(tokens)))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(currency(cost))
                .font(.system(size: 12, weight: .semibold))
        }
    }

}
