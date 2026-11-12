import AppKit

@MainActor
enum CodexRestartPromptPresenter {
    static func presentForModelChanges(store: TokenStore) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.launchCodexPromptTitle
        alert.informativeText = L.modelChangeRestartPromptMessage
        alert.addButton(withTitle: L.launchCodexPromptConfirm)
        alert.addButton(withTitle: L.launchCodexPromptCancel)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.acknowledgeCodexReload()
        Task {
            do {
                _ = try await CodexDesktopLaunchProbeService.shared.restartCodex()
            } catch {
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .warning
                errorAlert.messageText = L.zh ? "无法重启 Codex" : "Could Not Restart Codex"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: L.zh ? "好" : "OK")
                errorAlert.runModal()
            }
        }
    }
}
