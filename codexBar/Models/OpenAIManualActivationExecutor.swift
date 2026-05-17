import Foundation

enum OpenAIManualActivationExecutor {
    static func execute(
        targetAccountID: String,
        targetMode: CodexBarOpenAIAccountUsageMode,
        activate: () throws -> Void
    ) async throws -> OpenAIManualSwitchResult {
        let action = OpenAIManualActivationResolver.resolve()
        try activate()

        return OpenAIManualSwitchResult(
            action: action,
            targetAccountID: targetAccountID,
            targetMode: targetMode,
            launchedNewInstance: false
        )
    }
}
