import Foundation

struct DailyCostEntry: Identifiable, Codable {
    let id: String
    let date: Date
    let costUSD: Double
    let totalTokens: Int
}

struct LocalCostSummary: Codable {
    var todayCostUSD: Double
    var todayTokens: Int
    var last30DaysCostUSD: Double
    var last30DaysTokens: Int
    var lifetimeCostUSD: Double
    var lifetimeTokens: Int
    var dailyEntries: [DailyCostEntry]
    var updatedAt: Date?

    static let empty = LocalCostSummary(
        todayCostUSD: 0,
        todayTokens: 0,
        last30DaysCostUSD: 0,
        last30DaysTokens: 0,
        lifetimeCostUSD: 0,
        lifetimeTokens: 0,
        dailyEntries: [],
        updatedAt: nil
    )

    func isStaleForLocalDay(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let updatedAt else { return true }
        return calendar.isDate(updatedAt, inSameDayAs: now) == false
    }
}
