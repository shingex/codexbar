import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsRecordsViewModel: ObservableObject {
    @Published private(set) var snapshot: RecordsSnapshot?
    @Published private(set) var sessions: [HistoricalSessionRecord] = []
    @Published private(set) var models: [HistoricalModelRecord] = []
    @Published private(set) var warnings: [RecordsSnapshotWarning] = []
    @Published private(set) var listLoadState: ListLoadState = .idle
    @Published private(set) var detailLoadState: DetailLoadState = .idle
    @Published private(set) var isLoadingSnapshot = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var isLoadingTokenCount = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var detailErrorMessage: String?
    @Published private(set) var messages: [SessionMessageRecord] = []
    @Published private(set) var selectedSessionTokenCount: Int?
    @Published var searchText = ""
    @Published var selectedSessionID: String?
    @Published var expandedMessageID: String?
    @Published var selectedSessionIDs = Set<String>()
    @Published var isBatchMode = false
    @Published var isModelsSummaryExpanded = false
    @Published var isWarningsExpanded = false

    private let service: any RecordsSnapshotServing
    private var requestToken: UInt64 = 0
    private var messageRequestToken: UInt64 = 0
    private var tokenRequestToken: UInt64 = 0

    init(service: any RecordsSnapshotServing) {
        self.service = service
    }

    enum ListLoadState: Equatable {
        case idle
        case loadingCached
        case refreshing
        case finished
        case failed(String)
    }

    enum DetailLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var filteredSessions: [HistoricalSessionRecord] {
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return self.sessions }
        return self.sessions.filter { session in
            [
                session.sessionID,
                session.modelID,
                session.title ?? "",
                session.summary ?? "",
                session.projectDirectory ?? "",
                session.sourcePath ?? "",
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var selectedSession: HistoricalSessionRecord? {
        guard let selectedSessionID else { return nil }
        return self.filteredSessions.first { $0.sessionID == selectedSessionID }
    }

    var filteredModels: [HistoricalModelRecord] {
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return self.models }

        let visibleModelIDs = Set(self.filteredSessions.map(\.modelID))
        return self.models.filter {
            visibleModelIDs.contains($0.modelID) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var directoryItems: [SessionDirectoryItem] {
        let anchorIndexes = self.messages.indices.filter {
            self.messages[$0].role.lowercased() == "user" ||
                ($0 == self.messages.startIndex && Self.isDisplayableDirectoryAnchor(self.messages[$0]))
        }

        return anchorIndexes.enumerated().map { position, messageIndex in
            let nextUserIndex = anchorIndexes.dropFirst(position + 1).first ?? self.messages.endIndex
            let segment = Array(self.messages[messageIndex..<nextUserIndex])
            let message = self.messages[messageIndex]
            return SessionDirectoryItem(
                displayIndex: position + 1,
                title: Self.previewText(message.content, limit: 60),
                messages: segment
            )
        }
    }

    var archivedSessionCount: Int {
        self.filteredSessions.filter(\.isArchived).count
    }

    var selectedBatchSessions: [HistoricalSessionRecord] {
        self.filteredSessions.filter { self.selectedSessionIDs.contains($0.sessionID) }
    }

    var activeSessionCount: Int {
        self.filteredSessions.count - self.archivedSessionCount
    }

    var hasSnapshot: Bool {
        self.snapshot != nil || self.sessions.isEmpty == false
    }

    var shouldShowSkeleton: Bool {
        false
    }

    var statusText: String {
        if self.isRefreshingAll {
            return L.settingsRecordsRefreshingAll
        }
        switch self.listLoadState {
        case .idle:
            return L.settingsRecordsIdle
        case .loadingCached:
            return L.settingsRecordsLoading
        case .refreshing:
            return self.sessions.isEmpty
                ? L.settingsRecordsLoading
                : L.settingsRecordsCachedRefreshing
        case .failed(let message):
            return L.settingsRecordsRefreshFailedKeepingList(message)
        case .finished:
            guard let snapshot = self.snapshot else {
                return L.settingsRecordsIdle
            }
            return L.settingsRecordsLastUpdated(
                SettingsRecordsFormatters.absoluteDateTimeString(for: snapshot.generatedAt)
            )
        }
    }

    func pageDidAppear() {
        guard self.isLoadingSnapshot == false, self.isRefreshingAll == false else { return }
        self.loadCurrent()
    }

    func retryLoad() {
        self.loadCurrent()
    }

    func loadCurrent() {
        let requestToken = self.beginRequest(isRefreshAll: false)
        Task {
            do {
                for try await event in self.service.streamCurrentList() {
                    self.handleListEvent(token: requestToken, event: event)
                }
                self.finishListStream(token: requestToken)
            } catch {
                self.finishListStream(token: requestToken, errorMessage: self.displayMessage(for: error))
            }
        }
    }

    func refreshAll(timeout: TimeInterval = 15) {
        guard self.isRefreshingAll == false else { return }
        let requestToken = self.beginRequest(isRefreshAll: true)
        Task {
            do {
                let snapshot = try await self.service.refreshAll(timeout: timeout)
                self.finishRequest(token: requestToken, snapshot: snapshot, errorMessage: nil, isRefreshAll: true)
            } catch {
                self.finishRequest(token: requestToken, snapshot: nil, errorMessage: self.displayMessage(for: error), isRefreshAll: true)
            }
        }
    }

    func selectSession(_ session: HistoricalSessionRecord) {
        self.selectedSessionID = session.sessionID
        self.expandedMessageID = nil
        self.detailErrorMessage = nil
        self.detailLoadState = .loading
        self.loadMessages(for: session)
        if session.totalTokens > 0 {
            self.tokenRequestToken += 1
            self.isLoadingTokenCount = false
            self.selectedSessionTokenCount = session.totalTokens
        } else {
            self.loadTokenCount(for: session)
        }
    }

    func toggleBatchMode() {
        self.isBatchMode.toggle()
        if self.isBatchMode == false {
            self.selectedSessionIDs.removeAll()
        }
    }

    func toggleBatchSelection(_ session: HistoricalSessionRecord) {
        if self.selectedSessionIDs.contains(session.sessionID) {
            self.selectedSessionIDs.remove(session.sessionID)
        } else {
            self.selectedSessionIDs.insert(session.sessionID)
        }
    }

    func selectAllFilteredSessions() {
        self.selectedSessionIDs = Set(self.filteredSessions.map(\.sessionID))
    }

    func deleteSessionsAfterConfirmation(_ sessions: [HistoricalSessionRecord]) {
        self.deleteSessions(sessions)
    }

    func toggleDirectoryItem(_ item: SessionDirectoryItem) {
        self.expandedMessageID = self.expandedMessageID == item.id ? nil : item.id
    }

    func copyProjectDirectory() {
        guard let directory = self.selectedSession?.projectDirectory else { return }
        Self.copyToPasteboard(directory)
    }

    func openProjectDirectory() {
        guard let directory = self.selectedSession?.projectDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    func copyResumeCommand() {
        guard let command = self.selectedSession?.resumeCommand else { return }
        Self.copyToPasteboard(command)
    }

    func copyMessage(_ message: SessionMessageRecord) {
        Self.copyToPasteboard(message.content)
    }

    func resumeSelectedSession() {
        guard let session = self.selectedSession else { return }
        Task {
            do {
                try await self.service.launchResumeTerminal(for: session)
            } catch {
                self.errorMessage = self.displayMessage(for: error)
            }
        }
    }

    func deleteSelectedSession() {
        guard let session = self.selectedSession else { return }
        self.deleteSessions([session])
    }

    func deleteSelectedBatchSessions() {
        self.deleteSessions(self.selectedBatchSessions)
    }

    private func deleteSessions(_ sessions: [HistoricalSessionRecord]) {
        guard sessions.isEmpty == false else { return }
        Task {
            let results = await self.service.deleteSessions(sessions)
            let failed = results.first { $0.didDelete == false }
            if let failed {
                self.errorMessage = failed.errorMessage ?? L.settingsRecordsDeleteFailed
                return
            }
            let deletedIDs = Set(results.filter(\.didDelete).map(\.sessionID))
            self.applySnapshot(self.snapshot.map { snapshot in
                RecordsSnapshot(
                    generatedAt: snapshot.generatedAt,
                    refreshMode: snapshot.refreshMode,
                    models: snapshot.models,
                    sessions: snapshot.sessions.filter { deletedIDs.contains($0.sessionID) == false },
                    warnings: snapshot.warnings
                )
            })
            self.selectedSessionIDs.subtract(deletedIDs)
            self.isBatchMode = false
            if let selectedSessionID, deletedIDs.contains(selectedSessionID) {
                self.selectedSessionID = nil
                self.clearSelectedSessionDetails()
            } else if self.selectedSession == nil {
                self.clearSelectedSessionDetails()
            }
        }
    }

    private var normalizedQuery: String {
        self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginRequest(isRefreshAll: Bool) -> UInt64 {
        self.requestToken += 1
        self.errorMessage = nil
        if isRefreshAll {
            self.isRefreshingAll = true
            self.isLoadingSnapshot = false
        } else {
            self.listLoadState = .loadingCached
            self.isLoadingSnapshot = true
        }
        return self.requestToken
    }

    private func finishRequest(
        token: UInt64,
        snapshot: RecordsSnapshot?,
        errorMessage: String?,
        isRefreshAll: Bool
    ) {
        guard token == self.requestToken else { return }
        self.isLoadingSnapshot = false
        if isRefreshAll {
            self.isRefreshingAll = false
        }
        if let snapshot {
            self.applySnapshot(snapshot)
            self.listLoadState = .finished
            if let selectedSessionID,
               snapshot.sessions.contains(where: { $0.sessionID == selectedSessionID }) == false {
                self.selectedSessionID = nil
                self.clearSelectedSessionDetails()
            } else if self.selectedSession == nil {
                self.clearSelectedSessionDetails()
            }
        } else if let errorMessage, isRefreshAll {
            self.listLoadState = .failed(errorMessage)
        }
        self.errorMessage = errorMessage
    }

    private func handleListEvent(token: UInt64, event: RecordsListEvent) {
        guard token == self.requestToken else { return }
        self.errorMessage = nil
        self.isLoadingSnapshot = true

        switch event {
        case .cached(let snapshot):
            self.applySnapshot(snapshot)
            self.listLoadState = .refreshing
        case .partial(let snapshot):
            self.applySnapshot(snapshot)
            self.listLoadState = .refreshing
        case .finished(let snapshot):
            self.applySnapshot(snapshot)
            self.listLoadState = .finished
            self.isLoadingSnapshot = false
        }

        if let selectedSessionID,
           self.sessions.contains(where: { $0.sessionID == selectedSessionID }) == false {
            self.selectedSessionID = nil
            self.clearSelectedSessionDetails()
        }
    }

    private func finishListStream(token: UInt64, errorMessage: String? = nil) {
        guard token == self.requestToken else { return }
        self.isLoadingSnapshot = false
        if let errorMessage {
            self.errorMessage = errorMessage
            self.listLoadState = .failed(errorMessage)
            return
        }
        if case .finished = self.listLoadState {
            return
        }
        self.listLoadState = .finished
    }

    private func applySnapshot(_ snapshot: RecordsSnapshot?) {
        self.snapshot = snapshot
        self.sessions = snapshot?.sessions ?? []
        self.models = snapshot?.models ?? []
        self.warnings = snapshot?.warnings ?? []
    }

    private func clearSelectedSessionDetails() {
        self.messageRequestToken += 1
        self.tokenRequestToken += 1
        self.isLoadingMessages = false
        self.isLoadingTokenCount = false
        self.detailLoadState = .idle
        self.detailErrorMessage = nil
        self.messages = []
        self.selectedSessionTokenCount = nil
        self.expandedMessageID = nil
    }

    private func loadMessages(for session: HistoricalSessionRecord) {
        self.messageRequestToken += 1
        let token = self.messageRequestToken
        self.isLoadingMessages = true
        self.messages = []
        Task {
            do {
                let messages = try await self.service.loadMessages(for: session)
                self.finishMessagesRequest(token: token, messages: messages, errorMessage: nil)
            } catch {
                self.finishMessagesRequest(token: token, messages: [], errorMessage: self.displayMessage(for: error))
            }
        }
    }

    private func finishMessagesRequest(
        token: UInt64,
        messages: [SessionMessageRecord],
        errorMessage: String?
    ) {
        guard token == self.messageRequestToken else { return }
        self.isLoadingMessages = false
        self.messages = messages
        if let errorMessage {
            self.detailLoadState = .failed(errorMessage)
            self.detailErrorMessage = errorMessage
        } else {
            self.detailLoadState = .loaded
            self.detailErrorMessage = nil
        }
    }

    private func loadTokenCount(for session: HistoricalSessionRecord) {
        self.tokenRequestToken += 1
        let token = self.tokenRequestToken
        self.isLoadingTokenCount = true
        self.selectedSessionTokenCount = nil
        Task {
            do {
                let tokenCount = try await self.service.loadTokenCount(for: session)
                self.finishTokenRequest(token: token, tokenCount: tokenCount, errorMessage: nil)
            } catch {
                self.finishTokenRequest(token: token, tokenCount: nil, errorMessage: self.displayMessage(for: error))
            }
        }
    }

    private func finishTokenRequest(
        token: UInt64,
        tokenCount: Int?,
        errorMessage: String?
    ) {
        guard token == self.tokenRequestToken else { return }
        self.isLoadingTokenCount = false
        self.selectedSessionTokenCount = tokenCount
        if let errorMessage {
            self.detailErrorMessage = errorMessage
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let serviceError = error as? RecordsSnapshotServiceError,
           case .timedOut = serviceError {
            return L.settingsRecordsRefreshTimeout
        }
        return error.localizedDescription
    }

    private static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    nonisolated private static func previewText(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    nonisolated private static func isDisplayableDirectoryAnchor(_ message: SessionMessageRecord) -> Bool {
        let role = message.role.lowercased()
        return role == "assistant" || role == "tool"
    }
}

struct SessionDirectoryItem: Identifiable, Equatable {
    let displayIndex: Int
    let title: String
    let messages: [SessionMessageRecord]

    var id: String { self.messages.first?.id ?? "\(self.displayIndex)" }
}

private struct SettingsRecordsToolbar: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                TextField(L.settingsRecordsSearchPlaceholder, text: self.$recordsModel.searchText)
                    .textFieldStyle(.roundedBorder)

                Button(L.settingsRecordsGoToUsageAction) {
                    self.onOpenUsage()
                }
            }

            HStack(alignment: .center, spacing: 8) {
                Button(L.settingsRecordsRefreshAction) {
                    self.recordsModel.refreshAll()
                }
                .disabled(self.recordsModel.isRefreshingAll)

                if self.recordsModel.isRefreshingAll || self.recordsModel.listLoadState == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(self.recordsModel.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsRecordsManagerLayout: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        SettingsRecordsSessionList(recordsModel: self.recordsModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsRecordsSessionList: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(L.settingsRecordsSessionsTitle)
                    .font(.system(size: 12, weight: .medium))

                Text("\(self.recordsModel.filteredSessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.10))
                    )

                Spacer(minLength: 12)

                SettingsRecordsBatchToolbar(recordsModel: self.recordsModel)
            }

            if self.recordsModel.filteredSessions.isEmpty {
                Text(self.recordsModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? self.emptyText
                     : L.settingsRecordsNoSearchResults)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(self.recordsModel.filteredSessions) { session in
                            SettingsRecordsSessionListRow(
                                session: session,
                                isSelected: self.recordsModel.selectedSessionID == session.sessionID,
                                isBatchMode: self.recordsModel.isBatchMode,
                                isChecked: self.recordsModel.selectedSessionIDs.contains(session.sessionID),
                                onToggleChecked: { self.recordsModel.toggleBatchSelection(session) }
                            ) {
                                self.openSessionDetail(session)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
    }

    private var emptyText: String {
        switch self.recordsModel.listLoadState {
        case .loadingCached, .refreshing:
            return L.settingsRecordsSessionsLoadingCompact
        default:
            return L.settingsRecordsSessionsEmpty
        }
    }

    private func openSessionDetail(_ session: HistoricalSessionRecord) {
        self.recordsModel.selectSession(session)
        DetachedWindowPresenter.shared.show(
            id: "settings-records-session-detail",
            title: "\(L.settingsRecordsDetailWindowTitle) - \(session.displayTitle)",
            size: CGSize(width: 760, height: 640),
            configuration: DetachedWindowConfiguration(
                isResizable: true,
                contentMinSize: CGSize(width: 620, height: 420),
                resetsContentSizeOnReuse: false,
                level: .normal,
                activatesApp: false,
                makesKey: false
            )
        ) {
            SettingsRecordsConversationWindow(recordsModel: self.recordsModel)
        }
    }
}

private struct SettingsRecordsBatchToolbar: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    @State private var pendingDeleteSessions: [HistoricalSessionRecord] = []
    @State private var showsDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Button(self.recordsModel.isBatchMode ? L.settingsRecordsExitBatchAction : L.settingsRecordsBatchAction) {
                self.recordsModel.toggleBatchMode()
            }

            if self.recordsModel.isBatchMode {
                Button(L.settingsRecordsSelectAllAction) {
                    self.recordsModel.selectAllFilteredSessions()
                }
                Button(role: .destructive) {
                    self.pendingDeleteSessions = self.recordsModel.selectedBatchSessions
                    self.showsDeleteConfirmation = true
                } label: {
                    Text(L.settingsRecordsDeleteSelectedAction(self.recordsModel.selectedBatchSessions.count))
                }
                .buttonStyle(SettingsHoverButtonStyle(isDestructive: true))
                .disabled(self.recordsModel.selectedBatchSessions.isEmpty)
            }
        }
        .font(.system(size: 10))
        .confirmationDialog(
            L.settingsRecordsDeleteBatchConfirmTitle,
            isPresented: self.$showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L.deleteConfirm, role: .destructive) {
                self.recordsModel.deleteSessionsAfterConfirmation(self.pendingDeleteSessions)
                self.pendingDeleteSessions = []
            }
            Button(L.cancel, role: .cancel) {
                self.pendingDeleteSessions = []
            }
        } message: {
            Text(L.settingsRecordsDeleteBatchConfirmMessage(self.pendingDeleteSessions.count))
        }
    }
}

private struct SettingsRecordsSessionListRow: View {
    let session: HistoricalSessionRecord
    let isSelected: Bool
    let isBatchMode: Bool
    let isChecked: Bool
    let onToggleChecked: () -> Void
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if self.isBatchMode {
                Button(action: self.onToggleChecked) {
                    Image(systemName: self.isChecked ? "checkmark.square.fill" : "square")
                        .foregroundColor(self.isChecked ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble")
                        .foregroundColor(self.isSelected ? .accentColor : .secondary)
                    Text(self.session.displayTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    SettingsRecordsStatusBadge(isArchived: self.session.isArchived)
                }

                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(SettingsRecordsFormatters.relativeTimeString(for: self.session.startedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(self.backgroundColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture(perform: self.onSelect)
        .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return Color.accentColor.opacity(0.12)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.10)
        }
        return Color.clear
    }
}

private struct SettingsRecordsStatusBadge: View {
    let isArchived: Bool

    var body: some View {
        Text(self.isArchived ? L.settingsRecordsArchivedBadge : L.settingsRecordsActiveBadge)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(self.isArchived ? .secondary : .accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(self.isArchived ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(0.12))
            )
    }
}

private struct SettingsRecordsConversationWindow: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        SettingsRecordsConversationPanel(recordsModel: self.recordsModel)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsRecordsConversationPanel: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = self.recordsModel.selectedSession {
                SettingsRecordsHeaderActions(recordsModel: self.recordsModel)

                SettingsRecordsConversationHeader(
                    session: session,
                    recordsModel: self.recordsModel
                )

                if self.recordsModel.isLoadingMessages {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L.settingsRecordsLoading)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else if let detailErrorMessage = self.recordsModel.detailErrorMessage {
                    SettingsRecordsInlineMessage(
                        message: detailErrorMessage,
                        showsRetry: false,
                        onRetry: {}
                    )
                } else if self.recordsModel.directoryItems.isEmpty {
                    SettingsRecordsEmptyConversation()
                } else {
                    SettingsRecordsDirectoryList(recordsModel: self.recordsModel)
                }
            } else {
                SettingsRecordsSelectPrompt()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsRecordsConversationHeader: View {
    let session: HistoricalSessionRecord
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(self.session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
                Text(self.session.sessionID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            SettingsRecordsProjectFolderRow(session: self.session, recordsModel: self.recordsModel)

            HStack(spacing: 10) {
                SettingsRecordsInfoBlock(title: L.settingsRecordsModelTitle, value: self.session.modelID)
                SettingsRecordsTokenInfoBlock(recordsModel: self.recordsModel)
            }

            HStack(spacing: 10) {
                SettingsRecordsInfoColumn(
                    title: L.settingsRecordsStartedAtTitle,
                    value: SettingsRecordsFormatters.absoluteDateTimeString(for: self.session.startedAt)
                )
                SettingsRecordsInfoColumn(
                    title: L.settingsRecordsLastActivityTitle,
                    value: SettingsRecordsFormatters.absoluteDateTimeString(for: self.session.lastActivityAt)
                )
            }
        }
    }
}

private struct SettingsRecordsHeaderActions: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    @State private var pendingDeleteSession: HistoricalSessionRecord?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 8) {
            Button(L.settingsRecordsCopyDirectoryAction) {
                self.recordsModel.copyProjectDirectory()
            }
            .disabled(self.recordsModel.selectedSession?.projectDirectory == nil)

            Button(L.settingsRecordsCopyCommandAction) {
                self.recordsModel.copyResumeCommand()
            }
            .disabled(self.recordsModel.selectedSession?.resumeCommand == nil)

            Button(L.settingsRecordsResumeAction) {
                self.recordsModel.resumeSelectedSession()
            }
            .disabled(self.recordsModel.selectedSession?.resumeCommand == nil)

            Button(role: .destructive) {
                self.pendingDeleteSession = self.recordsModel.selectedSession
                self.showsDeleteConfirmation = true
            } label: {
                Text(L.settingsRecordsDeleteAction)
            }
            .buttonStyle(SettingsHoverButtonStyle(isDestructive: true))
            .disabled(self.recordsModel.selectedSession?.sourcePath == nil)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            L.settingsRecordsDeleteConfirmTitle,
            isPresented: self.$showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L.deleteConfirm, role: .destructive) {
                if let pendingDeleteSession {
                    self.recordsModel.deleteSessionsAfterConfirmation([pendingDeleteSession])
                }
                self.pendingDeleteSession = nil
            }
            Button(L.cancel, role: .cancel) {
                self.pendingDeleteSession = nil
            }
        } message: {
            Text(L.settingsRecordsDeleteConfirmMessage(self.pendingDeleteSession?.displayTitle ?? ""))
        }
    }
}

private struct SettingsRecordsProjectFolderRow: View {
    let session: HistoricalSessionRecord
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        if let directory = self.session.projectDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           directory.isEmpty == false {
            Button {
                self.recordsModel.openProjectDirectory()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(self.session.projectFolderName ?? directory)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.link)
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help(directory)
            .font(.system(size: 11))
        }
    }
}

private struct SettingsRecordsInfoColumn: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(self.value)
                .font(.system(size: 11))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRecordsInfoBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(self.value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct SettingsRecordsTokenInfoBlock: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.settingsRecordsTotalTokensTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            if self.recordsModel.isLoadingTokenCount {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(self.recordsModel.selectedSessionTokenCount.map(String.init) ?? "--")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private enum SettingsRecordsFormatters {
    nonisolated static func relativeTimeString(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L.zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    nonisolated static func absoluteDateTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L.zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")
        formatter.dateStyle = L.zh ? .medium : .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct SettingsRecordsDirectoryList: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.settingsRecordsDirectoryTitle)
                .font(.system(size: 12, weight: .medium))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(self.recordsModel.directoryItems) { item in
                        SettingsRecordsDirectoryRow(
                            item: item,
                            isExpanded: self.recordsModel.expandedMessageID == item.id,
                            onToggle: { self.recordsModel.toggleDirectoryItem(item) },
                            onCopy: {
                                if let message = item.messages.first {
                                    self.recordsModel.copyMessage(message)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsRecordsDirectoryRow: View {
    let item: SessionDirectoryItem
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(self.item.displayIndex)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                Text(self.item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)

                Spacer(minLength: 0)

                Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)
            }

            if self.isExpanded {
                SettingsRecordsMessageGroup(messages: self.item.messages, onCopyFirst: self.onCopy)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(self.isHovering ? Color.secondary.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: self.onToggle)
        .onHover { self.isHovering = $0 }
    }
}

private struct SettingsRecordsMessageGroup: View {
    let messages: [SessionMessageRecord]
    let onCopyFirst: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(self.messages.enumerated()), id: \.offset) { offset, message in
                SettingsRecordsMessageDetail(
                    message: message,
                    onCopy: offset == 0 ? self.onCopyFirst : {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    }
                )
            }
        }
        .padding(.leading, 30)
    }
}

private struct SettingsRecordsMessageDetail: View {
    let message: SessionMessageRecord
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(self.roleTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(self.roleColor)
                if let timestamp = self.message.timestamp {
                    Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(L.settingsRecordsCopyMessageAction) { self.onCopy() }
                .font(.system(size: 10))
            }

            Text(self.message.content)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(self.roleColor.opacity(0.08)))
    }

    private var roleTitle: String {
        switch self.message.role.lowercased() {
        case "user": return L.settingsRecordsUserMessageTitle
        case "assistant": return "AI"
        case "tool": return L.settingsRecordsToolMessageTitle
        default: return self.message.role
        }
    }

    private var roleColor: Color {
        switch self.message.role.lowercased() {
        case "user": return .accentColor
        case "assistant": return .blue
        case "tool": return .purple
        default: return .secondary
        }
    }
}

private struct SettingsRecordsLoadingSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
                    .frame(height: 44)
            }
        }
        .redacted(reason: .placeholder)
    }
}

private struct SettingsRecordsInlineMessage: View {
    let message: String
    let showsRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(self.message)
                    .font(.system(size: 11))
                if self.showsRetry {
                    Button(L.settingsRecordsRetryAction) {
                        self.onRetry()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}

private struct SettingsRecordsEmptyState: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.settingsRecordsEmptyState)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button(L.settingsRecordsRetryAction) {
                self.onRetry()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

private struct SettingsRecordsSelectPrompt: View {
    var body: some View {
        Text(L.settingsRecordsSelectSession)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private struct SettingsRecordsEmptyConversation: View {
    var body: some View {
        Text(L.settingsRecordsConversationEmpty)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}

typealias SettingsRecordsModel = SettingsRecordsViewModel

struct SettingsRecordsPage: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                Text(L.settingsRecordsPageTitle)
                    .font(.system(size: 16, weight: .semibold))

                Text(L.settingsRecordsPageHint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsRecordsToolbar(
                    recordsModel: self.recordsModel,
                    onOpenUsage: self.onOpenUsage
                )

                if let errorMessage = self.recordsModel.errorMessage {
                    SettingsRecordsInlineMessage(
                        message: errorMessage,
                        showsRetry: self.recordsModel.hasSnapshot == false,
                        onRetry: self.recordsModel.retryLoad
                    )
                }

                if self.recordsModel.hasSnapshot || self.recordsModel.isLoadingSnapshot || self.recordsModel.isRefreshingAll {
                    SettingsRecordsManagerLayout(recordsModel: self.recordsModel)
                } else {
                    SettingsRecordsEmptyState(onRetry: self.recordsModel.retryLoad)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .buttonStyle(SettingsHoverButtonStyle())
        .onAppear {
            self.recordsModel.pageDidAppear()
        }
    }
}
