import Foundation

enum OpenAIAccountUsageModeTransitionExecutor {
    static func execute(
        targetMode: CodexBarOpenAIAccountUsageMode,
        currentMode: @autoclosure () -> CodexBarOpenAIAccountUsageMode,
        applyMode: () throws -> Void
    ) async throws -> OpenAIManualActivationAction? {
        guard currentMode() != targetMode else { return nil }
        try applyMode()
        return .updateConfigOnly
    }
}
