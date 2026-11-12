import Foundation

enum SettingsSaveRequestApplier {
    static func apply(
        _ requests: SettingsSaveRequests,
        to config: inout CodexBarConfig
    ) throws {
        self.apply(requests.openAIAccount, to: &config)
        self.apply(requests.openAIUsage, to: &config)
        try self.apply(requests.desktop, to: &config)
    }

    static func apply(_ request: OpenAIAccountSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
        config.setOpenAIAccountOrder(request.accountOrder)
        config.setOpenAIAccountUsageMode(request.accountUsageMode)
    }

    static func apply(_ request: OpenAIUsageSettingsUpdate?, to config: inout CodexBarConfig) {
        guard let request else { return }
        if let seconds = request.pollingIntervalSeconds {
            config.openAI.usagePollingIntervalSeconds = UsagePollingInterval.normalized(seconds)
        }
        if let mode = request.usageDisplayMode {
            config.openAI.usageDisplayMode = mode
        }
    }


    static func apply(_ request: DesktopSettingsUpdate?, to config: inout CodexBarConfig) throws {
        guard let request else { return }
        config.desktop.preferredCodexAppPath = try self.validatedPreferredCodexAppPath(
            from: request.preferredCodexAppPath
        )
    }

    static func validatedPreferredCodexAppPath(from preferredCodexAppPath: String?) throws -> String? {
        let trimmedPreferredPath = preferredCodexAppPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPreferredPath.isEmpty {
            return nil
        }

        guard let validatedPath = CodexDesktopLaunchProbeService
            .validatedPreferredCodexAppURL(from: trimmedPreferredPath)?
            .path else {
            throw TokenStoreError.invalidCodexAppPath
        }

        return validatedPath
    }
}
