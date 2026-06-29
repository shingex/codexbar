import SwiftUI

struct ResetCreditHoverPanelView: View {
    static let panelWidth: CGFloat = 282
    static let shadowPadding: CGFloat = 22
    private static let verticalPadding: CGFloat = 24
    private static let headerHeight: CGFloat = 22
    private static let queriedAtHeight: CGFloat = 14
    private static let tableHeaderHeight: CGFloat = 12
    private static let rowHeight: CGFloat = 19
    private static let emptyListHeight: CGFloat = 18
    private static let noCacheHeight: CGFloat = 44
    private static let errorMinHeight: CGFloat = 18
    private static let sectionSpacing: CGFloat = 10
    private static let tableSpacing: CGFloat = 6

    static var windowWidth: CGFloat {
        self.panelWidth + self.shadowPadding * 2
    }

    static func panelHeight(snapshot: CodexResetCreditSnapshot?, errorMessage: String? = nil) -> CGFloat {
        var height = self.verticalPadding + self.headerHeight
        if let snapshot {
            height += self.sectionSpacing + self.queriedAtHeight
            height += self.sectionSpacing + self.tableHeaderHeight + self.tableSpacing
            height += snapshot.credits.isEmpty
                ? self.emptyListHeight
                : CGFloat(snapshot.credits.count) * self.rowHeight
        } else {
            height += self.sectionSpacing + self.noCacheHeight
        }
        if errorMessage?.isEmpty == false {
            height += self.sectionSpacing + self.errorMinHeight
        }
        return ceil(height)
    }

    static func windowHeight(snapshot: CodexResetCreditSnapshot?, errorMessage: String? = nil) -> CGFloat {
        self.panelHeight(snapshot: snapshot, errorMessage: errorMessage) + self.shadowPadding * 2
    }

    let snapshot: CodexResetCreditSnapshot?
    let isRefreshing: Bool
    let errorMessage: String?
    let queryTime: (Date) -> String
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header

            if let snapshot {
                Text("\(L.resetCreditLastQueried): \(self.queryTime(snapshot.queriedAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                self.creditList(snapshot)
            } else {
                Text(L.resetCreditNoCache)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(
            width: Self.panelWidth,
            height: Self.panelHeight(snapshot: self.snapshot, errorMessage: self.errorMessage),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.56))
                )
                .shadow(color: Color.black.opacity(0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(Self.shadowPadding)
        .frame(
            width: Self.windowWidth,
            height: Self.windowHeight(snapshot: self.snapshot, errorMessage: self.errorMessage),
            alignment: .center
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L.resetCreditCount(self.snapshot?.availableCount ?? 0))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                self.onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(self.isRefreshing ? 360 : 0))
            }
            .buttonStyle(.plain)
            .foregroundColor(self.isRefreshing ? .secondary : .accentColor)
            .disabled(self.isRefreshing)
            .help(L.resetCreditRefresh)
        }
    }

    private func creditList(_ snapshot: CodexResetCreditSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#").frame(width: 18, alignment: .leading)
                Text(L.resetCreditStatus).frame(width: 68, alignment: .leading)
                Text(L.resetCreditExpiresAt).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)

            if snapshot.credits.isEmpty {
                Text(L.resetCreditEmptyList)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(snapshot.credits.enumerated()), id: \.element.id) { index, credit in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .frame(width: 18, alignment: .leading)
                            Text(credit.status)
                                .frame(width: 68, alignment: .leading)
                                .foregroundColor(self.statusColor(credit.status))
                            Text(credit.expiresAt?.timeLocal ?? "-")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .frame(height: Self.rowHeight - 5, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        status.lowercased() == "available" ? .green : .secondary
    }
}
