import Foundation

enum UsagePollingInterval {
    nonisolated static let defaultOpenAI = 300
    nonisolated static let defaultOpenCode = 900

    nonisolated static func normalized(_ seconds: Int) -> Int {
        seconds > 0 ? max(seconds, Int(UsageHTTPRefreshClient.minimumInterval)) : 0
    }

    nonisolated static func nanoseconds(_ seconds: Int) -> UInt64 {
        UInt64(min(max(seconds, 0), Int(UInt64.max / 1_000_000_000))) * 1_000_000_000
    }
}
