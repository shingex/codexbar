import Foundation
import XCTest

final class OpenCodePlanDetectionServiceTests: CodexBarTestCase {
    func testDetectPlanReturnsGoWhenGoUsageIsAvailable() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/inference/go/v1/usage")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"usage":{}}"#.utf8))
        }
        let service = OpenCodePlanDetectionService(urlSession: self.makeMockSession())

        let plan = try await service.detectPlan(apiKey: "sk-opencode")
        XCTAssertEqual(plan, .go)
    }

    func testDetectPlanReturnsZenWhenGoUsageIsUnavailableButZenModelsAreAvailable() async throws {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/inference/go/v1/usage" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            XCTAssertEqual(request.url?.path, "/inference/v1/models")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"object":"list","data":[]}"#.utf8))
        }
        let service = OpenCodePlanDetectionService(urlSession: self.makeMockSession())

        let plan = try await service.detectPlan(apiKey: "sk-opencode")
        XCTAssertEqual(plan, .zen)
    }

    func testDetectPlanRejectsInvalidCredential() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let service = OpenCodePlanDetectionService(urlSession: self.makeMockSession())

        do {
            _ = try await service.detectPlan(apiKey: "sk-invalid")
            XCTFail("expected invalid credential")
        } catch {
            XCTAssertEqual(error as? OpenCodePlanDetectionError, .invalidCredential)
        }
    }
}
