import Combine
import AppKit
import SwiftUI

struct SettingsSkillUpdateActivity: Equatable {
    let skillID: String
    let phase: SettingsSkillUpdatePhase
}

enum SettingsSkillUpdatePhase: Equatable {
    case checking
    case updating
}

@MainActor
final class SettingsSkillsViewModel: ObservableObject {
    @Published private(set) var skills: [CodexSkillSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDiscoveringUpdateSources = false
    @Published private(set) var updateActivity: SettingsSkillUpdateActivity?
    @Published var message: SettingsSkillsInlineMessageState?

    private let service: CodexSkillService
    private var reloadTask: Task<Void, Never>?
    private var gitSourceDiscoveryTask: Task<Void, Never>?
    private var skillUpdateTask: Task<Void, Never>?

    init(service: CodexSkillService) {
        self.service = service
    }

    deinit {
        self.gitSourceDiscoveryTask?.cancel()
        self.skillUpdateTask?.cancel()
    }

    var skillsDirectoryPath: String {
        self.service.skillsDirectoryURL.path
    }

    var enabledCount: Int {
        self.skills.filter { $0.status == .enabled }.count
    }

    var disabledCount: Int {
        self.skills.filter { $0.status == .disabled }.count
    }

    var invalidCount: Int {
        self.skills.filter { $0.status == .invalid }.count
    }

    func pageDidAppear() {
        self.reload()
    }

    func reload(discoverGitSources: Bool = true, preserveMessage: Bool = false) {
        self.reloadTask?.cancel()
        self.isLoading = true
        let service = self.service
        self.reloadTask = Task.detached {
            let result = Result { try service.loadSkills() }
            await MainActor.run {
                guard Task.isCancelled == false else { return }
                self.isLoading = false
                switch result {
                case .success(let skills):
                    self.skills = skills
                    if preserveMessage == false {
                        self.message = nil
                    }
                    if discoverGitSources {
                        self.startGitSourceDiscovery(preserveMessage: preserveMessage)
                    }
                case .failure(let error):
                    self.message = .error(error.localizedDescription)
                }
            }
        }
    }

    func createSkill(name: String, description: String) {
        do {
            _ = try self.service.createSkill(name: name, description: description)
            self.reload()
            self.message = .success(L.skillsCreatedMessage)
        } catch {
            self.message = .error(error.localizedDescription)
        }
    }

    func setSkill(_ skill: CodexSkillSummary, enabled: Bool) {
        do {
            try self.service.setSkill(skill, enabled: enabled)
            self.reload()
        } catch {
            self.message = .error(error.localizedDescription)
        }
    }

    func deleteSkill(_ skill: CodexSkillSummary) {
        do {
            try self.service.deleteSkill(skill)
            self.reload()
        } catch {
            self.message = .error(error.localizedDescription)
        }
    }

    func revealSkillsDirectory() {
        do {
            try self.service.revealSkillsDirectory()
            self.message = nil
        } catch {
            self.message = .error(error.localizedDescription)
        }
    }

    func revealSkill(_ skill: CodexSkillSummary) {
        self.service.revealSkill(skill)
    }

    func editSkillFile(_ skill: CodexSkillSummary) {
        self.service.openSkillFile(skill)
    }

    func copySkillPath(_ skill: CodexSkillSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(skill.directoryURL.path, forType: .string)
    }

    func checkSkillUpdate(
        _ skill: CodexSkillSummary,
        sourceURL: String,
        onUpdateAvailable: @escaping @MainActor (CodexSkillUpdatePlan) -> Void
    ) {
        guard self.updateActivity == nil else { return }
        self.skillUpdateTask?.cancel()
        self.updateActivity = SettingsSkillUpdateActivity(skillID: skill.id, phase: .checking)

        let service = self.service
        self.skillUpdateTask = Task { @MainActor in
            let result = await Task.detached {
                do {
                    return Result<CodexSkillUpdateAvailability, Error>.success(
                        try service.checkSkillUpdate(skill, sourceURL: sourceURL)
                    )
                } catch {
                    return Result<CodexSkillUpdateAvailability, Error>.failure(error)
                }
            }.value

            guard Task.isCancelled == false else { return }
            guard self.updateActivity == SettingsSkillUpdateActivity(skillID: skill.id, phase: .checking) else { return }
            self.updateActivity = nil

            switch result {
            case .success(let availability):
                switch availability {
                case .upToDate:
                    self.message = .info(L.skillsAlreadyLatestMessage(skill.displayName))
                    self.reload(discoverGitSources: false, preserveMessage: true)
                case .updateAvailable(let plan):
                    self.message = nil
                    onUpdateAvailable(plan)
                }
            case .failure(let error):
                self.message = .error(error.localizedDescription)
            }
        }
    }

    func copyUpdateCommand(for plan: CodexSkillUpdatePlan) {
        let command = self.service.updateCommand(for: plan)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        self.message = .success(L.skillsUpdateCommandCopied(plan.skill.displayName))
    }

    private func startGitSourceDiscovery(preserveMessage: Bool = false) {
        let targets = self.service.skillsNeedingGitSourceDiscovery(self.skills)
        guard targets.isEmpty == false else {
            self.gitSourceDiscoveryTask?.cancel()
            self.isDiscoveringUpdateSources = false
            return
        }

        self.gitSourceDiscoveryTask?.cancel()
        self.isDiscoveringUpdateSources = true
        let service = self.service
        self.gitSourceDiscoveryTask = Task.detached {
            let discoveredSources = await service.discoverGitSources(for: targets)
            await MainActor.run {
                guard Task.isCancelled == false else { return }
                self.isDiscoveringUpdateSources = false
                if discoveredSources.isEmpty == false {
                    self.reload(discoverGitSources: false, preserveMessage: preserveMessage)
                }
            }
        }
    }

}

struct SettingsSkillsPage: View {
    @StateObject private var model: SettingsSkillsViewModel
    @State private var isCreatingSkill = false
    @State private var pendingAlert: SettingsSkillsPendingAlert?
    @State private var searchText = ""
    @State private var statusFilter: SettingsSkillsStatusFilter = .all
    @State private var selectedSkillID: String?

    @MainActor
    init() {
        self._model = StateObject(wrappedValue: SettingsSkillsViewModel(service: CodexSkillService()))
    }

    @MainActor
    init(model: SettingsSkillsViewModel) {
        self._model = StateObject(wrappedValue: model)
    }

    var body: some View {
        let filteredSkills = self.model.filteredSkills(
            matching: self.searchText,
            statusFilter: self.statusFilter
        )
        let selectedSkill = self.selectedSkill(in: filteredSkills)

        VStack(alignment: .leading, spacing: 16) {
            self.header

            if let message = self.model.message {
                SettingsSkillsInlineMessage(message: message)
            }

            if self.model.skills.isEmpty && self.model.isLoading == false {
                SettingsSkillsEmptyState(
                    skillsDirectoryPath: self.model.skillsDirectoryPath,
                    onCreate: { self.isCreatingSkill = true },
                    onReveal: self.model.revealSkillsDirectory
                )
        } else {
            SettingsSkillsBoard(
                    skills: filteredSkills,
                    selectedSkill: selectedSkill,
                    selectedSkillID: selectedSkill?.id,
                    totalSkillCount: self.model.skills.count,
                    filteredSkillCount: filteredSkills.count,
                    enabledCount: self.model.enabledCount,
                    disabledCount: self.model.disabledCount,
                    invalidCount: self.model.invalidCount,
                    searchText: self.$searchText,
                    statusFilter: self.$statusFilter,
                    onSelect: { self.selectedSkillID = $0.id },
                    onReset: self.resetFilters,
                    onSetEnabled: self.model.setSkill,
                    onReveal: self.model.revealSkill,
                    onCheckUpdate: self.checkSkillUpdate,
                    onEdit: self.model.editSkillFile,
                onCopyPath: self.model.copySkillPath,
                onDelete: { self.pendingAlert = .delete($0) },
                updateActivity: self.model.updateActivity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }
                .settingsDetailPagePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .buttonStyle(SettingsHoverButtonStyle())
        .onAppear {
            self.model.pageDidAppear()
        }
        .onChange(of: self.searchText) { _ in
            self.selectedSkillID = nil
        }
        .onChange(of: self.statusFilter) { _ in
            self.selectedSkillID = nil
        }
        .sheet(isPresented: self.$isCreatingSkill) {
            SettingsCreateSkillSheet { name, description in
                self.model.createSkill(name: name, description: description)
                self.isCreatingSkill = false
            } onCancel: {
                self.isCreatingSkill = false
            }
        }
        .alert(item: self.$pendingAlert) { alert in
            switch alert {
            case .delete(let skill):
                return Alert(
                    title: Text(L.skillsDeleteConfirmTitle),
                    message: Text(L.skillsDeleteConfirmMessage(skill.displayName)),
                    primaryButton: .destructive(Text(L.deleteConfirm)) {
                        self.model.deleteSkill(skill)
                    },
                    secondaryButton: .cancel(Text(L.cancel))
                )
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                self.headerTitle
                Spacer(minLength: 16)
                self.headerActions
            }

            HStack(alignment: .center, spacing: 12) {
                self.headerTitle
                Spacer(minLength: 10)
                self.compactHeaderActions
            }
        }
    }

    private var headerTitle: some View {
        Text(L.settingsSkillsPageTitle)
            .font(.system(size: 24, weight: .bold))
            .lineLimit(1)
    }

    private var headerActions: some View {
        HStack(alignment: .top, spacing: 20) {
            self.reloadButton(isCompact: false)
            self.revealDirectoryButton(isCompact: false)
            self.createSkillButton(isCompact: false)
        }
    }

    private var compactHeaderActions: some View {
        HStack(spacing: 12) {
            self.reloadButton(isCompact: true)
            self.revealDirectoryButton(isCompact: true)
            self.createSkillButton(isCompact: true)
        }
    }

    private func reloadButton(isCompact: Bool) -> some View {
        Button {
            self.model.reload()
        } label: {
            self.headerActionLabel(
                L.skillsReloadAction,
                systemImage: "arrow.clockwise",
                isCompact: isCompact
            )
        }
        .buttonStyle(SettingsHoverButtonStyle(minWidth: isCompact ? 40 : 76, minHeight: 40))
        .help(L.skillsReloadAction)
    }

    private func revealDirectoryButton(isCompact: Bool) -> some View {
        Button {
            self.model.revealSkillsDirectory()
        } label: {
            self.headerActionLabel(
                L.skillsRevealFolderAction,
                systemImage: "folder",
                isCompact: isCompact
            )
        }
        .buttonStyle(SettingsHoverButtonStyle(minWidth: isCompact ? 40 : 100, minHeight: 40))
        .help(L.skillsRevealFolderAction)
    }

    @ViewBuilder
    private func createSkillButton(isCompact: Bool) -> some View {
        if isCompact {
            Button {
                self.isCreatingSkill = true
            } label: {
                self.headerActionLabel(
                    L.skillsCreateAction,
                    systemImage: "plus",
                    isCompact: true
                )
            }
            .buttonStyle(SettingsHoverButtonStyle(isPrimary: true, minWidth: 42, minHeight: 40))
            .help(L.skillsCreateAction)
        } else {
            Button {
                self.isCreatingSkill = true
            } label: {
                self.headerActionLabel(
                    L.skillsCreateAction,
                    systemImage: "plus",
                    isCompact: false
                )
            }
            .buttonStyle(SettingsSkillsPrimaryButtonStyle())
            .help(L.skillsCreateAction)
        }
    }

    @ViewBuilder
    private func headerActionLabel(_ title: String, systemImage: String, isCompact: Bool) -> some View {
        if isCompact {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 18, height: 18)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func resetFilters() {
        self.searchText = ""
        self.statusFilter = .all
        self.selectedSkillID = nil
    }

    private func selectedSkill(in skills: [CodexSkillSummary]) -> CodexSkillSummary? {
        if let selectedSkillID,
           let selected = skills.first(where: { $0.id == selectedSkillID }) {
            return selected
        }
        return skills.first
    }

    private func checkSkillUpdate(_ skill: CodexSkillSummary, sourceURL: String) {
        self.model.checkSkillUpdate(skill, sourceURL: sourceURL) { plan in
            self.model.copyUpdateCommand(for: plan)
        }
    }
}

private enum SettingsSkillsPendingAlert: Identifiable {
    case delete(CodexSkillSummary)

    var id: String {
        switch self {
        case .delete(let skill):
            return "delete|\(skill.id)"
        }
    }
}

private extension SettingsSkillsViewModel {
    func filteredSkills(
        matching query: String,
        statusFilter: SettingsSkillsStatusFilter
    ) -> [CodexSkillSummary] {
        self.skills.filter { skill in
            skill.matchesSearchQuery(query) && statusFilter.matches(skill)
        }
    }
}

private struct SettingsSkillsBoard: View {
    let skills: [CodexSkillSummary]
    let selectedSkill: CodexSkillSummary?
    let selectedSkillID: String?
    let totalSkillCount: Int
    let filteredSkillCount: Int
    let enabledCount: Int
    let disabledCount: Int
    let invalidCount: Int
    @Binding var searchText: String
    @Binding var statusFilter: SettingsSkillsStatusFilter
    let onSelect: (CodexSkillSummary) -> Void
    let onReset: () -> Void
    let onSetEnabled: (CodexSkillSummary, Bool) -> Void
    let onReveal: (CodexSkillSummary) -> Void
    let onCheckUpdate: (CodexSkillSummary, String) -> Void
    let onEdit: (CodexSkillSummary) -> Void
    let onCopyPath: (CodexSkillSummary) -> Void
    let onDelete: (CodexSkillSummary) -> Void
    let updateActivity: SettingsSkillUpdateActivity?

    var body: some View {
        GeometryReader { proxy in
            let detailWidth = self.detailWidth(for: proxy.size.width)
            let sidebarWidth = max(proxy.size.width - detailWidth - 1, 0)
            HStack(spacing: 0) {
                self.sidebar
                    .frame(width: sidebarWidth)
                    .clipped()

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(width: 1)

                self.detail
                    .frame(width: detailWidth)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsSkillsPanel()
        .clipped()
    }

    private func detailWidth(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 560 {
            let compactSidebarWidth = min(224, max(204, availableWidth * 0.42))
            return max(availableWidth - compactSidebarWidth - 1, 240)
        }

        let minimumSidebarWidth: CGFloat = 240
        let maximumDetailWidth = max(availableWidth - minimumSidebarWidth - 1, 320)
        let preferredDetailWidth = min(620, max(availableWidth * 0.62, 360))
        return min(preferredDetailWidth, maximumDetailWidth)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSkillsSearchField(text: self.$searchText)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        self.filterPills(style: .wide)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    LazyVGrid(
                        columns: [
                            GridItem(.fixed(92), spacing: 6),
                            GridItem(.fixed(92), spacing: 6),
                        ],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        self.filterPills(style: .compact)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if self.filteredSkillCount == 0 {
                SettingsSkillsSearchEmptyState(
                    searchText: self.searchText,
                    statusFilterTitle: self.statusFilter.title,
                    onReset: self.onReset
                )
                .padding(.horizontal, 18)
                .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.skills) { skill in
                            SettingsSkillListRow(
                                skill: skill,
                                isSelected: skill.id == self.selectedSkillID,
                                onSelect: { self.onSelect(skill) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func filterPills(style: SettingsSkillsFilterPillStyle) -> some View {
                    SettingsSkillsFilterPill(
                        filter: .all,
                        count: self.totalSkillCount,
                        style: style,
                        selection: self.$statusFilter
                    )
                    SettingsSkillsFilterPill(
                        filter: .enabled,
                        count: self.enabledCount,
                        style: style,
                        selection: self.$statusFilter
                    )
                    SettingsSkillsFilterPill(
                        filter: .disabled,
                        count: self.disabledCount,
                        style: style,
                        selection: self.$statusFilter
                    )
                    SettingsSkillsFilterPill(
                        filter: .invalid,
                        count: self.invalidCount,
                        style: style,
                        selection: self.$statusFilter
                    )
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedSkill {
            SettingsSkillDetailPane(
                skill: selectedSkill,
                onSetEnabled: self.onSetEnabled,
                onReveal: self.onReveal,
                onCheckUpdate: self.onCheckUpdate,
                onEdit: self.onEdit,
                onCopyPath: self.onCopyPath,
                onDelete: self.onDelete,
                updatePhase: selectedSkill.id == self.updateActivity?.skillID ? self.updateActivity?.phase : nil
            )
            .id(selectedSkill.id)
        } else {
            SettingsSkillsNoSelectionPane()
        }
    }
}

private enum SettingsSkillsStatusFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled
    case invalid

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .all:
            return L.skillsFilterAll
        case .enabled:
            return L.skillsFilterEnabled
        case .disabled:
            return L.skillsFilterDisabled
        case .invalid:
            return L.skillsFilterNeedsFix
        }
    }

    func matches(_ skill: CodexSkillSummary) -> Bool {
        switch self {
        case .all:
            return true
        case .enabled:
            return skill.status == .enabled
        case .disabled:
            return skill.status == .disabled
        case .invalid:
            return skill.status == .invalid
        }
    }
}

private enum SettingsSkillsFilterPillStyle {
    case wide
    case compact

    var fixedWidth: CGFloat? {
        switch self {
        case .wide:
            return nil
        case .compact:
            return 92
        }
    }
}

private struct SettingsSkillsFilterPill: View {
    let filter: SettingsSkillsStatusFilter
    let count: Int
    let style: SettingsSkillsFilterPillStyle
    @Binding var selection: SettingsSkillsStatusFilter

    var body: some View {
        Button {
            self.selection = self.filter
        } label: {
            HStack(spacing: 7) {
                Text(self.filter.title)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(self.count)")
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(self.isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .lineLimit(1)
            .frame(width: self.style.fixedWidth, height: 30)
            .fixedSize(horizontal: self.style.fixedWidth == nil, vertical: false)
            .background(self.background, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var isSelected: Bool {
        self.selection == self.filter
    }

    private var background: Color {
        self.isSelected ? SettingsSkillsPalette.accent : Color(nsColor: .controlBackgroundColor)
    }
}

private struct SettingsSkillsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            TextField(L.skillsSearchPlaceholder, text: self.$text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))

            if self.text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button {
                    self.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .accessibilityLabel(L.skillsClearSearchAction)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
        .accessibilityLabel(L.skillsSearchAccessibilityLabel)
    }
}

private struct SettingsSkillListRow: View {
    let skill: CodexSkillSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if self.isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .fill(SettingsSkillsPalette.accent.opacity(0.08))
                Rectangle()
                    .fill(SettingsSkillsPalette.accent)
                    .frame(width: 2)
            }

            HStack(spacing: 12) {
                SettingsSkillStatusDot(status: self.skill.status)

                Text(self.skill.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: self.onSelect)
        .overlay(alignment: .bottom) {
            if self.isSelected == false {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(height: 1)
                    .padding(.leading, 42)
                    .padding(.trailing, 12)
            }
        }
    }
}

private struct SettingsSkillDetailPane: View {
    let skill: CodexSkillSummary
    let onSetEnabled: (CodexSkillSummary, Bool) -> Void
    let onReveal: (CodexSkillSummary) -> Void
    let onCheckUpdate: (CodexSkillSummary, String) -> Void
    let onEdit: (CodexSkillSummary) -> Void
    let onCopyPath: (CodexSkillSummary) -> Void
    let onDelete: (CodexSkillSummary) -> Void
    let updatePhase: SettingsSkillUpdatePhase?
    @State private var updateSourceText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                self.header
                self.actionBar
                self.updateSection

                self.pathSection

                SettingsSkillsDetailSection(title: L.skillsDescriptionTitle) {
                    self.descriptionField
                }

                SettingsSkillsDetailSection(title: L.skillsInfoTitle) {
                    SettingsSkillsInfoGrid(skill: self.skill)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            self.resetUpdateSourceText()
        }
        .onChange(of: self.skill.id) { _ in
            self.resetUpdateSourceText()
        }
        .onChange(of: self.skill.updateSourceURL ?? "") { _ in
            self.resetUpdateSourceText()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            self.editButton
            self.deleteButton
            Spacer(minLength: 0)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    self.updateTitle
                    Spacer(minLength: 12)
                    self.updateButton
            }

            HStack(alignment: .center, spacing: 12) {
                self.updateTitle
                Spacer(minLength: 8)
                self.updateButton
            }

            VStack(alignment: .leading, spacing: 8) {
                self.updateTitle
                self.updateButton
            }
        }

            TextField(L.skillsUpdateSourcePlaceholder, text: self.$updateSourceText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
                }
                .help(self.updateSourceText.isEmpty ? L.skillsUpdateSourcePlaceholder : self.updateSourceText)
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.pathHeader

            self.pathField
        }
    }

    private var pathHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                self.pathTitle
                Spacer(minLength: 12)
                self.pathActions(isCompact: false)
            }

            HStack(alignment: .center, spacing: 12) {
                self.pathTitle
                Spacer(minLength: 8)
                self.pathActions(isCompact: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                self.pathTitle
                self.pathActions(isCompact: false)
            }

            VStack(alignment: .leading, spacing: 8) {
                self.pathTitle
                self.pathActions(isCompact: true)
            }
        }
    }

    private var pathTitle: some View {
        Text(L.skillsPathTitle)
            .font(.system(size: 14, weight: .bold))
    }

    private func pathActions(isCompact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                self.onReveal(self.skill)
            } label: {
                self.pathActionLabel(
                    L.skillsOpenFolderAction,
                    systemImage: "folder",
                    isCompact: isCompact
                )
            }
            .buttonStyle(SettingsHoverButtonStyle(minWidth: isCompact ? 36 : nil, minHeight: 36))
            .help(L.skillsOpenFolderAction)

            Button {
                self.onCopyPath(self.skill)
            } label: {
                self.pathActionLabel(
                    L.skillsCopyPathAction,
                    systemImage: "doc.on.doc",
                    isCompact: isCompact
                )
            }
            .buttonStyle(SettingsHoverButtonStyle(minWidth: isCompact ? 36 : nil, minHeight: 36))
            .help(L.skillsCopyPathAction)
        }
    }

    @ViewBuilder
    private func pathActionLabel(_ title: String, systemImage: String, isCompact: Bool) -> some View {
        if isCompact {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 16, height: 16)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var descriptionField: some View {
        Text(self.skill.description.isEmpty ? "—" : self.skill.description)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.primary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            }
            .textSelection(.enabled)
    }

    private var pathField: some View {
        Text(SettingsSkillsFormatters.tildePath(for: self.skill.directoryURL))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .clipped()
            .padding(.horizontal, 12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            }
            .help(SettingsSkillsFormatters.tildePath(for: self.skill.directoryURL))
    }

    private var editButton: some View {
        Button {
            self.onEdit(self.skill)
        } label: {
            Label(L.skillsEditSkillFileAction, systemImage: "pencil")
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(SettingsSkillsActionButtonStyle())
    }

    private var updateButton: some View {
        Button {
            self.onCheckUpdate(self.skill, self.updateSourceText)
        } label: {
            HStack(spacing: 8) {
                if self.updatePhase == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(L.skillsUpdateSkillAction)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(self.updateButtonStyle)
        .disabled(self.updateSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.updatePhase == .updating)
        .help(self.updateSourceText.isEmpty ? L.skillsErrorGitRepositoryMissing : self.updateSourceText)
    }

    private var updateButtonStyle: AnyButtonStyle {
        if self.updatePhase == .updating {
            return AnyButtonStyle(SettingsSkillsProgressButtonStyle())
        }
        if self.updatePhase == .checking {
            return AnyButtonStyle(SettingsSkillsActionButtonStyle())
        }
        return AnyButtonStyle(SettingsSkillsActionButtonStyle())
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            self.onDelete(self.skill)
        } label: {
            Label(L.skillsDeleteSkillAction, systemImage: "trash")
        }
        .buttonStyle(SettingsSkillsDestructiveOutlineButtonStyle())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(self.skill.displayName)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)

            SettingsSkillStatusBadge(status: self.skill.status)

            Spacer(minLength: 16)

            Toggle(L.skillsEnabledToggle, isOn: Binding(
                get: { self.skill.status == .enabled },
                set: { self.onSetEnabled(self.skill, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(SettingsSkillsPalette.accent)
            .disabled(self.skill.status == .invalid && self.skill.skillFileURL == nil)
            .help(L.skillsEnabledToggle)
        }
    }

    private var updateTitle: some View {
        Text(L.skillsUpdateTitle)
            .font(.system(size: 14, weight: .bold))
    }

    private func resetUpdateSourceText() {
        self.updateSourceText = self.skill.updateSourceURL ?? ""
    }
}

private struct SettingsSkillsDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.title)
                .font(.system(size: 14, weight: .bold))
            self.content
        }
    }
}

private struct SettingsSkillsInfoGrid: View {
    let skill: CodexSkillSummary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsSkillsInfoCell(
                    title: L.skillsCreatedAtLabel,
                    value: SettingsSkillsFormatters.dateTimeString(for: self.skill.createdAt)
                )
                SettingsSkillsCellDivider()
                SettingsSkillsInfoCell(
                    title: L.skillsUpdatedAtLabel,
                    value: SettingsSkillsFormatters.dateTimeString(for: self.skill.modifiedAt)
                )
            }

            Divider()

            HStack(spacing: 0) {
                SettingsSkillsInfoCell(
                    title: L.skillsFileSizeLabel,
                    value: SettingsSkillsFormatters.fileSizeString(for: self.skill.fileSizeBytes)
                )
                SettingsSkillsCellDivider()
                SettingsSkillsInfoCell(
                    title: L.skillsFileNameLabel,
                    value: self.skill.skillFileURL?.lastPathComponent ?? "—"
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }
}

private struct SettingsSkillsInfoCell<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, value: String) where Content == Text {
        self.title = title
        self.content = Text(value)
    }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            self.content
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}

private struct SettingsSkillsCellDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(width: 1)
    }
}

private struct SettingsSkillStatusDot: View {
    let status: CodexSkillStatus

    var body: some View {
        Circle()
            .fill(SettingsSkillStatusBadge.color(for: self.status))
            .frame(width: 9, height: 9)
    }
}

private struct SettingsSkillStatusBadge: View {
    let status: CodexSkillStatus

    var body: some View {
        Text(Self.title(for: self.status))
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Self.color(for: self.status))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Self.color(for: self.status).opacity(0.14), in: Capsule())
    }

    static func title(for status: CodexSkillStatus) -> String {
        switch status {
        case .enabled:
            return L.skillsStatusEnabled
        case .disabled:
            return L.skillsStatusDisabled
        case .invalid:
            return L.skillsStatusInvalid
        }
    }

    static func color(for status: CodexSkillStatus) -> Color {
        switch status {
        case .enabled:
            return Color(red: 0.26, green: 0.72, blue: 0.32)
        case .disabled:
            return .secondary
        case .invalid:
            return .orange
        }
    }
}

private struct SettingsSkillsNoSelectionPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.secondary)
            Text(L.skillsSearchNoResultsTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct SettingsSkillsInlineMessageState: Equatable {
    let message: String
    let kind: Kind

    enum Kind: Equatable {
        case success
        case info
        case error
    }

    static func success(_ message: String) -> Self {
        Self(message: message, kind: .success)
    }

    static func info(_ message: String) -> Self {
        Self(message: message, kind: .info)
    }

    static func error(_ message: String) -> Self {
        Self(message: message, kind: .error)
    }
}

private struct SettingsSkillsInlineMessage: View {
    let message: SettingsSkillsInlineMessageState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: self.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(self.accentColor)

            Text(self.message.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.borderColor, lineWidth: 1)
            }
    }

    private var iconName: String {
        switch self.message.kind {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch self.message.kind {
        case .success:
            return Color(red: 0.16, green: 0.62, blue: 0.28)
        case .info:
            return Color(red: 0.23, green: 0.45, blue: 0.92)
        case .error:
            return Color(red: 0.78, green: 0.35, blue: 0.05)
        }
    }

    private var backgroundColor: Color {
        switch self.message.kind {
        case .success:
            return Color(red: 0.16, green: 0.62, blue: 0.28).opacity(0.14)
        case .info:
            return Color(red: 0.23, green: 0.45, blue: 0.92).opacity(0.12)
        case .error:
            return Color(red: 1.0, green: 0.64, blue: 0.12).opacity(0.16)
        }
    }

    private var borderColor: Color {
        switch self.message.kind {
        case .success:
            return Color(red: 0.16, green: 0.62, blue: 0.28).opacity(0.38)
        case .info:
            return Color(red: 0.23, green: 0.45, blue: 0.92).opacity(0.36)
        case .error:
            return Color(red: 0.94, green: 0.48, blue: 0.08).opacity(0.45)
        }
    }
}

private struct SettingsSkillsEmptyState: View {
    let skillsDirectoryPath: String
    let onCreate: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.skillsEmptyTitle)
                .font(.system(size: 16, weight: .bold))
            Text(L.skillsEmptyMessage(self.skillsDirectoryPath))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button(action: self.onCreate) {
                    Label(L.skillsCreateAction, systemImage: "plus")
                }
                Button(action: self.onReveal) {
                    Label(L.skillsRevealFolderAction, systemImage: "folder")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSkillsSurface(radius: 10)
    }
}

private struct SettingsSkillsSearchEmptyState: View {
    let searchText: String
    let statusFilterTitle: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.skillsSearchNoResultsTitle)
                .font(.system(size: 15, weight: .bold))
            Text(L.skillsSearchNoResultsMessage(self.searchText, self.statusFilterTitle))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: self.onReset) {
                Label(L.skillsResetFiltersAction, systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(SettingsHoverButtonStyle(minHeight: 36))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSkillsSurface(radius: 10)
    }
}

private struct SettingsCreateSkillSheet: View {
    @State private var name = ""
    @State private var description = ""

    let onCreate: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.skillsCreateSheetTitle)
                .font(SettingsTypography.pageTitle)

            VStack(alignment: .leading, spacing: 6) {
                Text(L.skillsCreateNameLabel)
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.secondary)
                TextField(L.skillsCreateNamePlaceholder, text: self.$name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L.skillsCreateDescriptionLabel)
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.secondary)
                TextField(L.skillsCreateDescriptionPlaceholder, text: self.$description)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Spacer()
                Button(L.cancel, action: self.onCancel)
                Button(L.skillsCreateAction) {
                    self.onCreate(self.name, self.description)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 230)
    }
}

private struct SettingsSkillsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(minWidth: 124, minHeight: 40)
            .background(
                LinearGradient(
                    colors: [
                        SettingsSkillsPalette.accent.opacity(configuration.isPressed ? 0.82 : 1),
                        SettingsSkillsPalette.accentDeep.opacity(configuration.isPressed ? 0.82 : 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

private struct SettingsSkillsDestructiveOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.red)
            .frame(minWidth: 118, minHeight: 34)
            .background(Color.red.opacity(configuration.isPressed ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.red.opacity(0.42), lineWidth: 1)
            }
    }
}

private struct SettingsSkillsProgressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(minWidth: 118, minHeight: 34)
            .background(
                LinearGradient(
                    colors: [
                        SettingsSkillsPalette.accent.opacity(configuration.isPressed ? 0.82 : 1),
                        SettingsSkillsPalette.accentDeep.opacity(configuration.isPressed ? 0.82 : 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(alignment: .leading) {
                if configuration.isPressed == false {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 0)
                }
            }
    }
}

private struct SettingsSkillsActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSkillsActionButtonBody(configuration: configuration)
    }
}

private struct SettingsSkillsActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        self.configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(self.foregroundColor)
            .padding(.horizontal, 18)
            .frame(minWidth: 118, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(self.borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { self.isHovering = $0 }
    }

    private var foregroundColor: Color {
        if self.isEnabled == false {
            return .secondary
        }
        return .primary
    }

    private var backgroundColor: Color {
        if self.isEnabled == false {
            return Color.secondary.opacity(0.06)
        }
        if self.configuration.isPressed {
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        }
        if self.isHovering {
            return Color.secondary.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if self.isEnabled == false {
            return Color(nsColor: .separatorColor).opacity(0.28)
        }
        if self.configuration.isPressed {
            return Color(nsColor: .separatorColor).opacity(0.9)
        }
        if self.isHovering {
            return Color(nsColor: .separatorColor).opacity(0.9)
        }
        return Color(nsColor: .separatorColor).opacity(0.7)
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        self.makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        self.makeBodyClosure(configuration)
    }
}

private struct SettingsSkillsSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: self.radius))
            .shadow(color: self.ringShadowColor, radius: 0.4, x: 0, y: 0)
            .shadow(color: self.depthShadowColor, radius: 2, x: 0, y: 1)
    }

    private var ringShadowColor: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var depthShadowColor: Color {
        self.colorScheme == .dark ? Color.clear : Color.black.opacity(0.04)
    }
}

private extension View {
    func settingsSkillsSurface(radius: CGFloat) -> some View {
        self.modifier(SettingsSkillsSurfaceModifier(radius: radius))
    }

    func settingsSkillsPanel() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    func settingsSkillsControlBorder(radius: CGFloat) -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}

private enum SettingsSkillsFormatters {
    static func tildePath(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func dateTimeString(for date: Date?) -> String {
        guard let date else { return "—" }
        return self.dateFormatter.string(from: date)
    }

    static func fileSizeString(for bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}

private enum SettingsSkillsPalette {
    static let accent = Color.accentColor
    static let accentDeep = Color.accentColor
}
