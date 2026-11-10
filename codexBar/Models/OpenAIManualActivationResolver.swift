import Foundation

enum OpenAIManualSwitchCopyKey: Equatable {
    case defaultTargetUpdated
    case launchedNewInstance
}

enum OpenAIImmediateEffectRecommendation: Equatable {
    case noneNeeded
    case launchNewInstance
}

enum OpenAIManualActivationAction: Equatable {
    case updateConfigOnly
    case launchNewInstance
}

struct OpenAIManualSwitchResult: Equatable {
    let action: OpenAIManualActivationAction
    let targetAccountID: String
    let targetMode: CodexBarOpenAIAccountUsageMode
    let launchedNewInstance: Bool
    let affectsRunningThreads: Bool
    let copyKey: OpenAIManualSwitchCopyKey
    let immediateEffectRecommendation: OpenAIImmediateEffectRecommendation

    init(
        action: OpenAIManualActivationAction,
        targetAccountID: String,
        targetMode: CodexBarOpenAIAccountUsageMode,
        launchedNewInstance: Bool
    ) {
        self.action = action
        self.targetAccountID = targetAccountID
        self.targetMode = targetMode
        self.launchedNewInstance = launchedNewInstance
        self.affectsRunningThreads = false
        self.copyKey = launchedNewInstance ? .launchedNewInstance : .defaultTargetUpdated
        self.immediateEffectRecommendation = .noneNeeded
    }
}

enum OpenAIManualActivationResolver {
    static func resolve() -> OpenAIManualActivationAction {
        .updateConfigOnly
    }
}
