import Foundation
import XCTest

final class OpenCodeModelCatalogServiceTests: CodexBarTestCase {
    func testDecodeModelsParsesMetadataAndFiltersExternalHarnessUnavailableModels() throws {
        let data = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "deepseek-v4.1-flash",
                  "name": "DeepSeek V4.1 Flash",
                  "family": "deepseek-flash",
                  "canonical_id": "deepseek/deepseek-v4.1-flash",
                  "limit": {"context": 1000000, "output": 384000},
                  "capabilities": {
                    "tools": {"supported": true},
                    "reasoning": {"supported": true, "effort": ["low", "high", "max"]}
                  },
                  "modalities": {"input": ["text", "image/png"], "output": ["text"]},
                  "api": {
                    "chat-completions": {"base_url": "https://opencode.ai/inference/go/openai/v1"}
                  },
                  "cost": {
                    "text": {
                      "input": {"price": 0.15, "cache": {"read": 0.003}},
                      "output": {"price": 0.6}
                    }
                  }
                },
                {
                  "id": "gpt-6.1-sol",
                  "name": "GPT-6.1 Sol",
                  "limit": {"context": 1050000, "output": 128000},
                  "api": {
                    "responses": {"base_url": "https://opencode.ai/inference/go/openai/v1"}
                  },
                  "cost": {"text": {"input": {"price": 2}, "output": {"price": 10}}}
                },
                {
                  "id": "deepseek-v4.1-flash-free",
                  "name": "Free Model",
                  "cost": {"text": {"input": {"price": 0}, "output": {"price": 0}}}
                },
                {
                  "id": "big-pickle",
                  "name": "Big Pickle",
                  "cost": {"text": {"input": {"price": 0}, "output": {"price": 0}}}
                },
                {
                  "id": "iceman-contributor-free",
                  "name": "Iceman Contributor Free",
                  "cost": {"text": {"input": {"price": 0}, "output": {"price": 0}}}
                }
              ]
            }
            """.utf8
        )

        let models = OpenCodeModelCatalogService.decodeModels(from: data)

        XCTAssertEqual(models.map(\.id), ["deepseek-v4.1-flash", "gpt-6.1-sol"])
        let deepSeek = try XCTUnwrap(models.first)
        XCTAssertEqual(deepSeek.name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(deepSeek.family, "deepseek-flash")
        XCTAssertEqual(deepSeek.contextLimit, 1_000_000)
        XCTAssertEqual(deepSeek.outputLimit, 384_000)
        XCTAssertTrue(deepSeek.supportsTools)
        XCTAssertEqual(deepSeek.reasoningEfforts, ["low", "high", "max"])
        XCTAssertTrue(deepSeek.inputModalities.contains("image/png"))
        XCTAssertEqual(deepSeek.nativeAPIs, ["chat-completions"])
        XCTAssertEqual(deepSeek.inputUSDPerMillion, 0.15)
        XCTAssertEqual(deepSeek.outputUSDPerMillion, 0.6)
        XCTAssertEqual(deepSeek.cacheReadUSDPerMillion, 0.003)

        let gpt = try XCTUnwrap(models.last)
        XCTAssertEqual(gpt.nativeAPIs, ["responses"])
        XCTAssertEqual(gpt.responsesBaseURL, "https://opencode.ai/inference/go/openai/v1")
    }

    func testFetchCatalogCachesAndReloadsEligibleModels() async throws {
        let payload = Data(
            #"{"object":"list","data":[{"id":"gpt-6.1-sol","name":"GPT-6.1 Sol","cost":{"text":{"input":{"price":2},"output":{"price":10}}},"api":{"responses":{"base_url":"https://opencode.ai/inference/go/openai/v1"}}}]}"#.utf8
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-opencode")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        let service = OpenCodeModelCatalogService(urlSession: self.makeMockSession())

        let snapshot = try await service.fetchCatalog(plan: .go, apiKey: "sk-opencode")
        XCTAssertEqual(snapshot.models.map(\.id), ["gpt-6.1-sol"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.openCodeModelCatalogURL(plan: .go).path))

        let cached = try XCTUnwrap(service.loadCachedCatalog(plan: .go))
        XCTAssertEqual(cached.models, snapshot.models)
        XCTAssertEqual(cached.fetchedAt.timeIntervalSince1970, snapshot.fetchedAt.timeIntervalSince1970, accuracy: 1)
    }
}
