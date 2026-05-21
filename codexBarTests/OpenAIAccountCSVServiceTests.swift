import Foundation
import XCTest

final class OpenAIAccountCSVServiceTests: CodexBarTestCase {
    func testMakeCSVExportsRhino2APIJSONPayload() throws {
        let service = OpenAIAccountCSVService()
        let activeAccount = try self.makeOAuthAccount(
            accountID: "acct_active",
            email: "active@example.com",
            isActive: true,
            oauthClientID: "app_active_client"
        )
        let inactiveAccount = try self.makeOAuthAccount(
            accountID: "acct_idle",
            email: "idle@example.com",
            oauthClientID: "app_idle_client"
        )
        let proxyKey = "http|127.0.0.1|7890||"
        let proxiesJSON = """
        [{"proxy_key":"http|127.0.0.1|7890||","name":"shadowrocket","protocol":"http","host":"127.0.0.1","port":7890,"status":"active"}]
        """
        let exportDate = Date(timeIntervalSince1970: 1_746_047_600)

        let exported = try service.makeCSV(
            from: [activeAccount, inactiveAccount],
            metadataByAccountID: [
                activeAccount.accountId: OAuthAccountInteropMetadata(
                    proxyKey: proxyKey,
                    notes: "primary",
                    concurrency: 10,
                    priority: 1,
                    rateMultiplier: 1,
                    autoPauseOnExpired: true,
                    credentialsJSON: #"{"privacy_mode":"training_off"}"#,
                    extraJSON: #"{"privacy_mode":"training_off"}"#
                ),
            ],
            proxiesJSON: proxiesJSON,
            now: exportDate
        )

        let payload = try self.parseJSONObject(exported)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(payload["exported_at"] as? String, formatter.string(from: exportDate))

        let proxies = try XCTUnwrap(payload["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies.first?["proxy_key"] as? String, proxyKey)

        let accounts = try XCTUnwrap(payload["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts.first?["platform"] as? String, "openai")
        XCTAssertEqual(accounts.first?["type"] as? String, "oauth")
        XCTAssertEqual(accounts.first?["proxy_key"] as? String, proxyKey)
        XCTAssertEqual(accounts.first?["concurrency"] as? Int, 10)
        XCTAssertEqual(accounts.first?["priority"] as? Int, 1)
        XCTAssertEqual(accounts.first?["auto_pause_on_expired"] as? Bool, true)

        let credentials = try XCTUnwrap(accounts.first?["credentials"] as? [String: Any])
        XCTAssertEqual(credentials["access_token"] as? String, activeAccount.accessToken)
        XCTAssertEqual(credentials["refresh_token"] as? String, activeAccount.refreshToken)
        XCTAssertEqual(credentials["id_token"] as? String, activeAccount.idToken)
        XCTAssertEqual(credentials["client_id"] as? String, "app_active_client")
        XCTAssertEqual(credentials["chatgpt_account_id"] as? String, activeAccount.remoteAccountId)
    }

    func testMakeCSVForAccountIDExportsOnlySelectedAccount() throws {
        let service = OpenAIAccountCSVService()
        let selectedAccount = try self.makeOAuthAccount(accountID: "acct_selected", email: "selected@example.com")
        let otherAccount = try self.makeOAuthAccount(accountID: "acct_other", email: "other@example.com")
        let snapshot = OAuthAccountExportSnapshot(
            accounts: [selectedAccount, otherAccount],
            metadataByAccountID: [
                selectedAccount.accountId: OAuthAccountInteropMetadata(
                    proxyKey: "http|127.0.0.1|7890||",
                    notes: nil,
                    concurrency: 2,
                    priority: nil,
                    rateMultiplier: nil,
                    autoPauseOnExpired: nil,
                    credentialsJSON: nil,
                    extraJSON: nil
                ),
                otherAccount.accountId: OAuthAccountInteropMetadata(
                    proxyKey: "http|127.0.0.1|7891||",
                    notes: nil,
                    concurrency: 9,
                    priority: nil,
                    rateMultiplier: nil,
                    autoPauseOnExpired: nil,
                    credentialsJSON: nil,
                    extraJSON: nil
                ),
            ],
            proxiesJSON: """
            [
              {"proxy_key":"http|127.0.0.1|7890||","name":"selected","protocol":"http","host":"127.0.0.1","port":7890,"status":"active"},
              {"proxy_key":"http|127.0.0.1|7891||","name":"other","protocol":"http","host":"127.0.0.1","port":7891,"status":"active"}
            ]
            """
        )

        let exported = try XCTUnwrap(
            service.makeCSV(
                forAccountID: selectedAccount.accountId,
                from: snapshot,
                now: Date(timeIntervalSince1970: 1_746_047_600)
            )
        )

        let payload = try self.parseJSONObject(exported)
        let accounts = try XCTUnwrap(payload["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?["name"] as? String, "selected@example.com")
        XCTAssertEqual(accounts.first?["proxy_key"] as? String, "http|127.0.0.1|7890||")
        XCTAssertEqual(accounts.first?["concurrency"] as? Int, 2)
    }

    func testMakeCSVForAccountIDReturnsNilForMissingAccount() throws {
        let service = OpenAIAccountCSVService()
        let account = try self.makeOAuthAccount(accountID: "acct_existing", email: "existing@example.com")
        let snapshot = OAuthAccountExportSnapshot(
            accounts: [account],
            metadataByAccountID: [:],
            proxiesJSON: nil
        )

        XCTAssertNil(try service.makeCSV(forAccountID: "acct_missing", from: snapshot))
    }

    func testParseCSVAcceptsRhino2APIFormat() throws {
        let service = OpenAIAccountCSVService()
        let account = try self.makeOAuthAccount(
            accountID: "acct_imported",
            email: "imported@example.com",
            oauthClientID: "app_imported_client"
        )
        let payload = """
        {
          "exported_at" : "2026-04-22T01:00:39Z",
          "proxies" : [
            {
              "proxy_key" : "http|192.168.31.165|7897||",
              "name" : "shadowrocket",
              "protocol" : "http",
              "host" : "192.168.31.165",
              "port" : 7897,
              "status" : "active"
            }
          ],
          "accounts" : [
            {
              "name" : "imported@example.com",
              "platform" : "openai",
              "type" : "oauth",
              "credentials" : {
                "access_token" : "\(account.accessToken)",
                "refresh_token" : "\(account.refreshToken)",
                "id_token" : "\(account.idToken)",
                "client_id" : "app_imported_client",
                "email" : "imported@example.com",
                "chatgpt_account_id" : "\(account.remoteAccountId)",
                "expires_at" : 1777682631
              },
              "extra" : {
                "email" : "imported@example.com",
                "privacy_mode" : "training_off"
              },
              "proxy_key" : "http|192.168.31.165|7897||",
              "concurrency" : 10,
              "priority" : 1,
              "rate_multiplier" : 1,
              "auto_pause_on_expired" : true
            }
          ]
        }
        """

        let parsed = try service.parseCSV(payload)

        XCTAssertEqual(parsed.rowCount, 1)
        XCTAssertNil(parsed.activeAccountID)
        XCTAssertEqual(parsed.accounts.first?.accountId, account.accountId)
        XCTAssertEqual(parsed.accounts.first?.remoteAccountId, account.remoteAccountId)
        XCTAssertEqual(parsed.accounts.first?.email, "imported@example.com")
        XCTAssertEqual(parsed.interopContext.accountMetadataByID[account.accountId]?.proxyKey, "http|192.168.31.165|7897||")
        XCTAssertEqual(parsed.interopContext.accountMetadataByID[account.accountId]?.concurrency, 10)
        XCTAssertEqual(parsed.interopContext.accountMetadataByID[account.accountId]?.priority, 1)
        XCTAssertEqual(parsed.interopContext.accountMetadataByID[account.accountId]?.rateMultiplier, 1)
        XCTAssertEqual(parsed.interopContext.accountMetadataByID[account.accountId]?.autoPauseOnExpired, true)
        XCTAssertNotNil(parsed.interopContext.proxiesJSON)
    }

    func testParseCSVStillAcceptsLegacyCSVImport() throws {
        let service = OpenAIAccountCSVService()
        let account = try self.makeOAuthAccount(accountID: "acct_legacy", email: "legacy@example.com", isActive: true)
        let csv = """
        format_version,email,account_id,access_token,refresh_token,id_token,is_active
        v1,\(account.email),\(account.accountId),\(account.accessToken),\(account.refreshToken),\(account.idToken),true
        """

        let parsed = try service.parseCSV(csv)

        XCTAssertEqual(parsed.rowCount, 1)
        XCTAssertEqual(parsed.activeAccountID, account.accountId)
        XCTAssertEqual(parsed.accounts.first?.accountId, account.accountId)
        XCTAssertEqual(parsed.interopContext, .empty)
    }

    func testParseCSVAcceptsCodexAuthJSON() throws {
        let service = OpenAIAccountCSVService()
        let account = try self.makeOAuthAccount(
            accountID: "acct_auth_json",
            email: "auth-json@example.com",
            oauthClientID: "app_auth_json_client"
        )
        let payload = """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "client_id": "app_auth_json_client",
          "last_refresh": "2026-05-20T01:02:03Z",
          "tokens": {
            "access_token": "\(account.accessToken)",
            "refresh_token": "\(account.refreshToken)",
            "id_token": "\(account.idToken)",
            "account_id": "\(account.remoteAccountId)"
          }
        }
        """

        let parsed = try service.parseCSV(payload)

        XCTAssertEqual(parsed.rowCount, 1)
        XCTAssertEqual(parsed.activeAccountID, account.accountId)
        XCTAssertEqual(parsed.accounts.first?.accountId, account.accountId)
        XCTAssertEqual(parsed.accounts.first?.remoteAccountId, account.remoteAccountId)
        XCTAssertEqual(parsed.accounts.first?.email, "auth-json@example.com")
        XCTAssertEqual(parsed.accounts.first?.oauthClientID, "app_auth_json_client")
        XCTAssertEqual(parsed.interopContext, .empty)
    }

    func testParseCSVRejectsFilesWithoutImportableOpenAIOAuthAccounts() throws {
        let service = OpenAIAccountCSVService()
        let payload = """
        {
          "exported_at" : "2026-04-22T01:00:39Z",
          "proxies" : [],
          "accounts" : [
            {
              "name" : "anthropic-key",
              "platform" : "anthropic",
              "type" : "apikey",
              "credentials" : {
                "api_key" : "sk-test"
              },
              "concurrency" : 1,
              "priority" : 1
            }
          ]
        }
        """

        XCTAssertThrowsError(try service.parseCSV(payload)) { error in
            XCTAssertEqual(error as? OpenAIAccountCSVError, .noImportableAccounts)
        }
    }

    private func parseJSONObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
