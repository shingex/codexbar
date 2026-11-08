import Foundation
import XCTest

final class OpenCodeCostLedgerServiceTests: CodexBarTestCase {
    func testRecordAndLoadDeduplicatesByResponseIDAndCollectsSessionIDs() throws {
        let url = CodexPaths.realHome.appendingPathComponent(".codexbar/test-opencode-cost-ledger.jsonl")
        let service = OpenCodeCostLedgerService(fileURL: url)
        let first = OpenCodeCostEvent(
            responseID: "resp-1",
            sessionID: "session-1",
            timestamp: Date(timeIntervalSince1970: 100),
            modelID: "deepseek-v4.1-flash",
            costUSD: 0.25,
            listCostUSD: 0.25,
            allowanceUSD: 0.1,
            billingSource: "go",
            inputTokens: 100,
            outputTokens: 20,
            cachedInputTokens: 10,
            cacheWriteTokens: 0
        )
        let duplicate = OpenCodeCostEvent(
            responseID: "resp-1",
            sessionID: "session-1",
            timestamp: Date(timeIntervalSince1970: 101),
            modelID: "deepseek-v4.1-flash",
            costUSD: 0.25,
            listCostUSD: 0.25,
            allowanceUSD: 0.1,
            billingSource: "go",
            inputTokens: 100,
            outputTokens: 20,
            cachedInputTokens: 10,
            cacheWriteTokens: 0
        )
        let second = OpenCodeCostEvent(
            responseID: "resp-2",
            sessionID: "session-2",
            timestamp: Date(timeIntervalSince1970: 102),
            modelID: "gpt-6.1-sol",
            costUSD: 0.5,
            listCostUSD: nil,
            allowanceUSD: nil,
            billingSource: "zen",
            inputTokens: 200,
            outputTokens: 40,
            cachedInputTokens: 0,
            cacheWriteTokens: 0
        )

        service.record(first)
        service.record(duplicate)
        service.record(second)
        let snapshot = service.load()

        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.events.map(\.responseID), ["resp-1", "resp-2"])
        XCTAssertEqual(snapshot.sessionIDs, ["session-1", "session-2"])
        XCTAssertEqual(snapshot.events.first?.totalTokens, 120)
    }
}
