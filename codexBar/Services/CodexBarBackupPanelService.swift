import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct CodexBarBackupPanelService {
    typealias AppActivator = @MainActor () -> Void
    typealias RestoreURLRequester = @MainActor (_ kind: CodexBarBackupKind) -> URL?
    typealias DirectoryOpener = @MainActor (_ url: URL) -> Void
    typealias FileRevealer = @MainActor (_ url: URL) -> Void

    private let activateApp: AppActivator
    private let requestRestoreURLAction: RestoreURLRequester
    private let openDirectoryAction: DirectoryOpener
    private let revealFileAction: FileRevealer

    init(
        activateApp: @escaping AppActivator = { CodexBarBackupPanelService.activateApp() },
        requestRestoreURLAction: @escaping RestoreURLRequester = { kind in
            CodexBarBackupPanelService.presentRestorePanel(kind: kind)
        },
        openDirectoryAction: @escaping DirectoryOpener = { url in
            _ = NSWorkspace.shared.open(url)
        },
        revealFileAction: @escaping FileRevealer = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.activateApp = activateApp
        self.requestRestoreURLAction = requestRestoreURLAction
        self.openDirectoryAction = openDirectoryAction
        self.revealFileAction = revealFileAction
    }

    func requestRestoreURL(kind: CodexBarBackupKind) -> URL? {
        self.activateApp()
        return self.requestRestoreURLAction(kind)
    }

    func openBackupsDirectory(_ url: URL) {
        self.activateApp()
        self.openDirectoryAction(url)
    }

    func revealBackupFile(_ url: URL) {
        self.activateApp()
        self.revealFileAction(url)
    }

    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func presentRestorePanel(kind: CodexBarBackupKind) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L.backupRestorePanelTitle(kind.panelTitle)
        panel.prompt = L.backupRestorePanelPrompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = CodexPaths.backupsRootURL
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private extension CodexBarBackupKind {
    var panelTitle: String {
        switch self {
        case .codexbarSettings:
            return L.backupCodexBarCardTitle
        case .codexConfig:
            return L.backupCodexCardTitle
        }
    }
}
