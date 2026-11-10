import Foundation
import XCTest

final class GatewayCapacityRetryPolicyTests: XCTestCase {
    func testOnlyErrorEnvelopesMatchCapacity() {
        let message = "Selected model is at capacity. Please try a different model."
        XCTAssertTrue(GatewayCapacityRetryPolicy.isCapacityError(["error": ["message": message.uppercased()]]))
        XCTAssertTrue(GatewayCapacityRetryPolicy.isCapacityError(["type": "response.failed", "response": ["error": ["message": message]]]))
        XCTAssertFalse(GatewayCapacityRetryPolicy.isCapacityError(["output_text": message]))
        XCTAssertFalse(GatewayCapacityRetryPolicy.isCapacityBody(Data(message.utf8), statusCode: 200))
        XCTAssertFalse(GatewayCapacityRetryPolicy.isCapacityError(["error": ["message": "rate limit exceeded"]]))
    }

    func testBackoffAndRetryAfter() {
        XCTAssertEqual((1...4).compactMap { GatewayCapacityRetryPolicy.delay(attempt: $0, retryAfter: nil, jitter: 1) }, [5, 10, 20, 30])
        XCTAssertEqual(GatewayCapacityRetryPolicy.delay(attempt: 1, retryAfter: "12", jitter: 1.2), 12)
        XCTAssertEqual(GatewayCapacityRetryPolicy.delay(attempt: 2, retryAfter: "1", jitter: 1.2), 12)
        XCTAssertNil(GatewayCapacityRetryPolicy.delay(attempt: 1, retryAfter: "121", jitter: 1))
        XCTAssertEqual(GatewayCapacityRetryPolicy.delay(attempt: 1, retryAfter: "invalid", jitter: 1), 5)
        XCTAssertEqual(GatewayCapacityRetryPolicy.delay(attempt: 1, retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970: 0), jitter: 1), 60)
        XCTAssertEqual(GatewayCapacityRetryPolicy.maximumAttempts, 5)
    }

    func testSSELifecycleAndBusinessClassification() {
        XCTAssertEqual(GatewayCapacityRetryPolicy.disposition(Data("data: {\"type\":\"response.created\",\"response\":{\"output\":[]}}\n\n".utf8)), .lifecycle)
        for type in ["response.output_text.delta", "response.reasoning_text.delta", "response.output_item.added", "response.function_call_arguments.delta"] {
            XCTAssertEqual(GatewayCapacityRetryPolicy.disposition(Data("data: {\"type\":\"\(type)\"}\n\n".utf8)), .business)
        }
        XCTAssertEqual(GatewayCapacityRetryPolicy.disposition(Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Selected model is at capacity. Please try a different model.\"}}}\n\n".utf8)), .capacity)
    }
}
