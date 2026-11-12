import Foundation
import XCTest
final class ToolHistoryCompatibilityTests: XCTestCase {
    func testEmptyCallAndResultArePairedAndCustomItemIsConverted() throws {
        let input = Data(#"{"model":"native","input":[{"type":"custom_tool_call","id":"ct_old","call_id":"","name":"apply_patch","input":"patch"},{"type":"custom_tool_call_output","call_id":"","output":"ok"}]}"#.utf8)
        let repaired = try ToolHistoryCompatibility.normalize(input)
        let root = try JSONSerialization.jsonObject(with: repaired) as! [String: Any]
        let items = root["input"] as! [[String: Any]]
        XCTAssertEqual(items[0]["call_id"] as? String, items[1]["call_id"] as? String)
        XCTAssertTrue((items[0]["id"] as! String).hasPrefix("ctc_"))
        XCTAssertEqual(try ToolHistoryCompatibility.normalize(repaired), repaired)
    }
    func testMixedInputDoesNotSkipTheToolAtIndex553() throws {
        var input: [Any] = (0..<553).map { _ in ["type": "message", "role": "user", "content": "history"] as Any }
        input[12] = "legacy text"
        input.append(["type": "function_call", "id": "fc_tool", "call_id": "", "name": "shell", "arguments": "{}"])
        input.append(["type": "function_call_output", "call_id": "", "output": "ok"])
        let data = try JSONSerialization.data(withJSONObject: ["input": input])
        let root = try JSONSerialization.jsonObject(with: ToolHistoryCompatibility.normalize(data)) as! [String: Any]
        let repaired = root["input"] as! [Any]
        XCTAssertEqual(repaired[12] as? String, "legacy text")
        XCTAssertEqual((repaired[553] as! [String: Any])["call_id"] as? String, "fc_tool")
        XCTAssertEqual((repaired[554] as! [String: Any])["call_id"] as? String, "fc_tool")
    }
    func testResponseCreateEnvelopeRepairsEmptyCalls() throws {
        let data = Data(#"{"type":"response.create","response":{"input":[{"type":"custom_tool_call","id":"ct_old","call_id":" "},{"type":"custom_tool_call_output","call_id":""}]}}"#.utf8)
        let root = try JSONSerialization.jsonObject(with: ToolHistoryCompatibility.normalize(data)) as! [String: Any]
        let items = (root["response"] as! [String: Any])["input"] as! [[String: Any]]
        XCTAssertEqual(items[0]["call_id"] as? String, "ct_old")
        XCTAssertEqual(items[1]["call_id"] as? String, "ct_old")
    }
    func testAmbiguousResultsAreRejected() {
        let data = Data(#"{"input":[{"type":"function_call","call_id":"a"},{"type":"function_call","call_id":"b"},{"type":"function_call_output","call_id":""}]}"#.utf8)
        XCTAssertThrowsError(try ToolHistoryCompatibility.normalize(data))
    }
    func testResultReferencesToItemIDsResolveToTheCallID() throws {
        let data = Data(#"{"input":[{"type":"function_call","id":"fc_item","call_id":"call_actual"},{"type":"function_call_output","call_id":"fc_item","output":"ok"}]}"#.utf8)
        let root = try JSONSerialization.jsonObject(with: ToolHistoryCompatibility.normalize(data)) as! [String: Any]
        let items = root["input"] as! [[String: Any]]
        XCTAssertEqual(items[1]["call_id"] as? String, "call_actual")
    }
    func testValidOfficialBodyIsByteIdentical() throws {
        let data = Data(#"{ "input": [{"type":"function_call","id":"fc_ok","call_id":"a"},{"type":"function_call_output","call_id":"a","output":"ok"}], "model":"native" }"#.utf8)
        XCTAssertEqual(try ToolHistoryCompatibility.normalize(data), data)
    }
    func testNativeContextOutputsBecomeOrdinaryMessages() throws {
        let data = Data(#"{"input":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]},{"type":"function_call_output","id":"fco_page","name":"codex_apps_open_page","namespace":"agent","output":"{\"page_id\":null}"},{"type":"function_call_output","id":"fco_page_part","name":"codex_apps_selected_page_part_1_of_1","namespace":"agent","output":"snapshot"}]}"#.utf8)
        let repaired = try ToolHistoryCompatibility.normalize(data)
        let root = try JSONSerialization.jsonObject(with: repaired) as! [String: Any]
        let items = root["input"] as! [[String: Any]]
        XCTAssertEqual(items[1]["type"] as? String, "message")
        XCTAssertEqual(items[1]["role"] as? String, "user")
        XCTAssertTrue(String(decoding: repaired, as: UTF8.self).contains("page_id"))
        XCTAssertEqual(try ToolHistoryCompatibility.normalize(repaired), repaired)
    }
    func testContextRecordDoesNotStealPendingToolResult() throws {
        let data = Data(#"{"input":[{"type":"function_call","id":"fc_tool","call_id":"call_tool","name":"shell"},{"type":"function_call_output","id":"fco_page","name":"codex_apps_open_page","namespace":"agent","output":"{}"},{"type":"function_call_output","call_id":"","output":"ok"}]}"#.utf8)
        let root = try JSONSerialization.jsonObject(with: ToolHistoryCompatibility.normalize(data)) as! [String: Any]
        let items = root["input"] as! [[String: Any]]
        XCTAssertEqual(items[1]["call_id"] as? String, "call_tool")
        XCTAssertEqual(items[2]["type"] as? String, "message")
        XCTAssertEqual(items[2]["role"] as? String, "user")
    }
}
