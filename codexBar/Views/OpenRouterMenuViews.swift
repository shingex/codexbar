import SwiftUI

struct OpenRouterModelPickerDisplay: Equatable {
    static func models(
        cachedModels: [CodexBarOpenRouterModel],
        selectedModelIDs: Set<String>,
        initiallyPinnedModelIDs: [String],
        searchText: String
    ) -> [CodexBarOpenRouterModel] {
        let catalogByID = Dictionary(uniqueKeysWithValues: cachedModels.map { ($0.id, $0) })
        let initialPinnedSet = Set(initiallyPinnedModelIDs)
        let initiallyPinnedModels: [CodexBarOpenRouterModel] = initiallyPinnedModelIDs.compactMap { modelID in
            guard selectedModelIDs.contains(modelID) else { return nil }
            return catalogByID[modelID]
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearch.isEmpty == false else {
            let laterSelectedModels = cachedModels.filter {
                selectedModelIDs.contains($0.id) && initialPinnedSet.contains($0.id) == false
            }
            return initiallyPinnedModels + laterSelectedModels
        }

        let matchedModels = cachedModels.filter { model in
            initialPinnedSet.contains(model.id) == false &&
                (
                    model.id.localizedCaseInsensitiveContains(trimmedSearch) ||
                    model.name.localizedCaseInsensitiveContains(trimmedSearch)
                )
        }
        return initiallyPinnedModels + matchedModels
    }
}

struct OpenRouterModelPickerSection: View {
    @ObservedObject var store: TokenStore
    @Binding var apiKey: String
    @Binding var selectedModelIDs: Set<String>
    @Binding var cachedModels: [CodexBarOpenRouterModel]
    @Binding var fetchedAt: Date?

    let initiallyPinnedModelIDs: [String]
    let refreshAction: (String) async throws -> OpenRouterModelCatalogSnapshot

    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var note: String?
    @State private var autoRefreshAttemptedAPIKey: String?

    private var visibleModels: [CodexBarOpenRouterModel] {
        OpenRouterModelPickerDisplay.models(
            cachedModels: self.cachedModels,
            selectedModelIDs: self.selectedModelIDs,
            initiallyPinnedModelIDs: self.initiallyPinnedModelIDs,
            searchText: self.searchText
        )
    }

    private var statusText: String {
        if self.cachedModels.isEmpty {
            return L.openRouterModelPickerNoCache
        }
        return L.openRouterModelPickerCacheStatus(count: self.cachedModels.count, fetchedAt: self.fetchedAt)
    }

    private var selectedCountText: String {
        L.openRouterModelPickerSelectedCount(self.selectedModelIDs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(self.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button(isRefreshing ? L.openRouterModelPickerRefreshing : L.openRouterModelPickerRefresh) {
                    Task {
                        await self.refreshModels()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                TextField(L.openRouterModelPickerSearchPlaceholder, text: $searchText)
                Text(self.selectedCountText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(self.visibleModels) { model in
                        Toggle(isOn: self.bindingForModel(model.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(model.id)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 7)
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if model.id != self.visibleModels.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }

                    if self.visibleModels.isEmpty {
                        Text(self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L.openRouterModelPickerSearchPrompt : L.openRouterModelPickerNoMatches)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 260)

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            self.refreshIfNeededForEmptyCache()
        }
        .onChange(of: apiKey) { _ in
            self.refreshIfNeededForEmptyCache()
        }
        .onChange(of: cachedModels) { _ in
            self.refreshIfNeededForEmptyCache()
        }
    }

    private func toggleModel(_ modelID: String) {
        if self.selectedModelIDs.contains(modelID) {
            self.selectedModelIDs.remove(modelID)
        } else {
            self.selectedModelIDs.insert(modelID)
        }
    }

    private func bindingForModel(_ modelID: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedModelIDs.contains(modelID) },
            set: { isSelected in
                if isSelected {
                    self.selectedModelIDs.insert(modelID)
                } else {
                    self.selectedModelIDs.remove(modelID)
                }
            }
        )
    }

    private func refreshIfNeededForEmptyCache() {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.cachedModels.isEmpty,
              trimmedAPIKey.isEmpty == false,
              self.isRefreshing == false,
              self.autoRefreshAttemptedAPIKey != trimmedAPIKey else {
            return
        }

        self.autoRefreshAttemptedAPIKey = trimmedAPIKey
        Task {
            await self.refreshModels()
        }
    }

    private func refreshModels() async {
        self.isRefreshing = true
        self.note = nil
        defer {
            self.isRefreshing = false
        }

        do {
            let snapshot = try await self.refreshAction(self.apiKey)
            self.cachedModels = snapshot.models
            self.fetchedAt = snapshot.fetchedAt
            self.note = nil
        } catch {
            self.note = L.openRouterModelPickerRefreshFailure
        }
    }
}

struct OpenRouterKeyEditorSheet: View {
    let provider: CodexBarProvider
    @ObservedObject var store: TokenStore
    let onSave: (String, OpenRouterSelectionPayload) -> Void
    let onCancel: () -> Void

    @State private var apiKey = ""
    @State private var accountLabel = ""
    @State private var selectedModelIDs: Set<String>
    @State private var selectedModelID: String?
    @State private var cachedModels: [CodexBarOpenRouterModel]
    @State private var fetchedAt: Date?
    private let initialPinnedModelIDs: [String]

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        onSave: @escaping (String, OpenRouterSelectionPayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let inheritedCache = provider.openRouterProviderLevelSelection
        self._selectedModelIDs = State(initialValue: [])
        self._selectedModelID = State(initialValue: nil)
        self._cachedModels = State(initialValue: inheritedCache.cachedModelCatalog)
        self._fetchedAt = State(initialValue: inheritedCache.modelCatalogFetchedAt)
        self.initialPinnedModelIDs = []
    }

    init(
        provider: CodexBarProvider,
        store: TokenStore,
        account: CodexBarProviderAccount,
        onSave: @escaping (String, OpenRouterSelectionPayload) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let selection = provider.openRouterSelection(forAccountID: account.id)
        self._apiKey = State(initialValue: account.apiKey ?? "")
        self._accountLabel = State(initialValue: account.label)
        self._selectedModelID = State(initialValue: selection.effectiveModelID)
        self._selectedModelIDs = State(initialValue: Set(selection.pinnedModelIDs))
        self._cachedModels = State(initialValue: selection.cachedModelCatalog)
        self._fetchedAt = State(initialValue: selection.modelCatalogFetchedAt)
        self.initialPinnedModelIDs = selection.pinnedModelIDs
    }

    private var canSave: Bool {
        normalizedOpenRouterModelID(self.apiKey) != nil
    }

    private var selectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.selectedModelIDs,
            currentSelectedModelID: self.selectedModelID,
            cachedModels: self.cachedModels,
            fetchedAt: self.fetchedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OpenRouterKeyFormFields(apiKey: $apiKey, accountLabel: $accountLabel)

            OpenRouterModelPickerSection(
                store: self.store,
                apiKey: $apiKey,
                selectedModelIDs: $selectedModelIDs,
                cachedModels: $cachedModels,
                fetchedAt: $fetchedAt,
                initiallyPinnedModelIDs: initialPinnedModelIDs,
                refreshAction: { apiKey in
                    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                }
            )

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                Button(L.saveProviderAction) {
                    if let selectionPayload {
                        onSave(accountLabel, selectionPayload)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

struct OpenRouterKeyRowView: View {
    let provider: CodexBarProvider
    let account: CodexBarProviderAccount
    let isActiveProvider: Bool
    let activeAccountId: String?
    var usageData: CodexBarProviderUsageData?
    var usageDisplayMode: CodexBarUsageDisplayMode = .used
    var useActionTitle: String = L.useBtn
    var selectedModelIDOverride: String?
    let onActivate: () -> Void
    let onSelectModel: (String) -> Void
    let onEditModel: () -> Void
    let onDeleteAccount: () -> Void
    @State private var isHoveringProvider = false
    @State private var hoveringModelID: String?
    private let primaryActionWidth = MenuPanelLayout.primaryActionWidth

    private var isCurrentAccount: Bool {
        self.isActiveProvider && self.account.id == self.activeAccountId
    }

    private var modelOptions: [CodexBarOpenRouterModel] {
        self.provider.openRouterMenuModelOptions(forAccountID: self.account.id)
    }

    private func modelRowBackground(for modelID: String) -> Color {
        self.hoveringModelID == modelID ? Color.secondary.opacity(0.08) : Color.clear
    }

    private func isCurrentModel(_ model: CodexBarOpenRouterModel) -> Bool {
        let currentModelID = self.selectedModelIDOverride ??
            self.provider.openRouterEffectiveModelID(forAccountID: self.account.id)
        return self.isCurrentAccount &&
            currentModelID == model.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(self.isCurrentAccount ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(self.isCurrentAccount ? .accentColor : .primary)

                Text(account.maskedAPIKey)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: onEditModel) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .menuPanelHoverChrome(cornerRadius: 5)
            }

            if self.modelOptions.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.modelOptions) { model in
                        self.modelActionRow(model)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(L.openRouterNoModelsSelected)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(L.openRouterManageModelsAction) {
                        self.onEditModel()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .font(.system(size: 9, weight: .medium))
                    .menuPanelHoverChrome(cornerRadius: 6)
                }
            }

            if let usageData,
               usageData.isBalanceOnly == false {
                ProviderUsageInlineProgressView(
                    data: usageData,
                    usageDisplayMode: self.usageDisplayMode,
                    isCompact: true
                )
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, MenuPanelLayout.blockContentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    self.isCurrentAccount
                        ? Color.accentColor.opacity(self.isHoveringProvider ? 0.11 : 0.07)
                        : Color.secondary.opacity(self.isHoveringProvider ? 0.08 : 0.04)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    self.isCurrentAccount ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055),
                    lineWidth: 0.6
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { self.isHoveringProvider = $0 }
        .contextMenu {
            let objectName = L.openRouterKeyContextObject(self.account.label)

            Button {
                onEditModel()
            } label: {
                Label(L.editContextMenuItem(objectName), systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDeleteAccount()
            } label: {
                Label(L.deleteContextMenuItem(objectName), systemImage: "trash")
            }
        }
    }

    private func modelActionRow(_ model: CodexBarOpenRouterModel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.name != model.id {
                    Text(model.id)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if self.isCurrentModel(model) {
                MenuPanelCurrentIndicator(width: self.primaryActionWidth)
            } else if self.useActionTitle.isEmpty == false {
                Button {
                    self.onSelectModel(model.id)
                } label: {
                    Text(useActionTitle)
                        .frame(maxWidth: .infinity)
                        .frame(height: MenuPanelLayout.primaryActionHeight)
                }
                .buttonStyle(MenuPanelPrimaryActionButtonStyle())
                .font(.system(size: 9, weight: .medium))
                .frame(width: self.primaryActionWidth, alignment: .center)
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(self.modelRowBackground(for: model.id))
        )
        .onHover { hovering in
            self.hoveringModelID = hovering ? model.id : nil
        }
    }
}
