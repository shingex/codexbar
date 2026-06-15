import SwiftUI

enum AddProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case thirdParty
    case openRouter

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .custom:
            return "OpenAI中转"
        case .thirdParty:
            return "第三方模型"
        case .openRouter:
            return "OpenRouter"
        }
    }
}

struct ThirdPartyModelSelectionPayload: Equatable {
    let provider: CodexBarThirdPartyModelProvider
    let baseURL: String
    let selectedModelID: String?
    let pinnedModelIDs: [String]
}

struct OpenRouterSelectionPayload: Equatable {
    let apiKey: String
    let selectedModelID: String?
    let pinnedModelIDs: [String]
    let cachedModelCatalog: [CodexBarOpenRouterModel]
    let fetchedAt: Date?
}

func normalizedOpenRouterModelID(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func orderedPinnedOpenRouterModelIDs(
    selectedModelIDs: Set<String>,
    cachedModels: [CodexBarOpenRouterModel]
) -> [String] {
    CodexBarProvider.orderedOpenRouterModelIDs(
        Array(selectedModelIDs),
        cachedModelCatalog: cachedModels
    )
}

func makeOpenRouterSelectionPayload(
    apiKey: String,
    selectedModelIDs: Set<String>,
    currentSelectedModelID: String?,
    cachedModels: [CodexBarOpenRouterModel],
    fetchedAt: Date?
) -> OpenRouterSelectionPayload? {
    guard let normalizedAPIKey = normalizedOpenRouterModelID(apiKey) else {
        return nil
    }

    let orderedPinnedModelIDs = orderedPinnedOpenRouterModelIDs(
        selectedModelIDs: selectedModelIDs,
        cachedModels: cachedModels
    )
    let normalizedCurrentModelID = normalizedOpenRouterModelID(currentSelectedModelID ?? "")
    let selectedModelID: String?
    if let normalizedCurrentModelID,
       orderedPinnedModelIDs.contains(normalizedCurrentModelID) {
        selectedModelID = normalizedCurrentModelID
    } else {
        selectedModelID = nil
    }

    return OpenRouterSelectionPayload(
        apiKey: normalizedAPIKey,
        selectedModelID: selectedModelID,
        pinnedModelIDs: orderedPinnedModelIDs,
        cachedModelCatalog: cachedModels,
        fetchedAt: fetchedAt
    )
}
struct AddProviderSheet: View {
    @ObservedObject var store: TokenStore

    private let isEditing: Bool
    @State private var preset: AddProviderPreset
    @State private var label = ""
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""
    @State private var thirdPartyProvider: CodexBarThirdPartyModelProvider
    @State private var thirdPartySelectedModelIDs: Set<String>
    @State private var thirdPartySelectedModelID: String?
    @State private var openRouterSelectedModelIDs: Set<String>
    @State private var openRouterSelectedModelID: String?
    @State private var openRouterCachedModels: [CodexBarOpenRouterModel]
    @State private var openRouterFetchedAt: Date?
    private let openRouterSelectionInitialPinnedModelIDs: [String]

    let onSave: (
        AddProviderPreset,
        String,
        String,
        String,
        String,
        ThirdPartyModelSelectionPayload?,
        OpenRouterSelectionPayload?
    ) -> Void
    let onCancel: () -> Void

    init(
        store: TokenStore,
        defaultPreset: AddProviderPreset = .custom,
        onSave: @escaping (
            AddProviderPreset,
            String,
            String,
            String,
            String,
            ThirdPartyModelSelectionPayload?,
            OpenRouterSelectionPayload?
        ) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._preset = State(initialValue: defaultPreset)
        self.store = store
        self.isEditing = false
        self.onSave = onSave
        self.onCancel = onCancel
        self._thirdPartyProvider = State(initialValue: .deepSeek)
        self._thirdPartySelectedModelIDs = State(initialValue: [CodexBarThirdPartyModelProvider.deepSeek.defaultModel])
        self._thirdPartySelectedModelID = State(initialValue: CodexBarThirdPartyModelProvider.deepSeek.defaultModel)
        self._openRouterSelectedModelIDs = State(initialValue: [])
        self._openRouterSelectedModelID = State(initialValue: nil)
        self._openRouterCachedModels = State(initialValue: [])
        self._openRouterFetchedAt = State(initialValue: nil)
        self.openRouterSelectionInitialPinnedModelIDs = []
        if defaultPreset == .openRouter {
            self._label = State(initialValue: "OpenRouter")
        } else if defaultPreset == .thirdParty {
            self._label = State(initialValue: CodexBarThirdPartyModelProvider.deepSeek.title)
            self._baseURL = State(initialValue: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL)
        }
    }

    init(
        store: TokenStore,
        editingProvider provider: CodexBarProvider,
        editingAccount account: CodexBarProviderAccount? = nil,
        onSave: @escaping (
            AddProviderPreset,
            String,
            String,
            String,
            String,
            ThirdPartyModelSelectionPayload?,
            OpenRouterSelectionPayload?
        ) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let activeAccount = account ?? provider.activeAccount
        let openRouterSelection = activeAccount.map { provider.openRouterSelection(forAccountID: $0.id) } ??
            provider.openRouterProviderLevelSelection
        let thirdPartyProvider = provider.thirdPartyModelProvider ?? .deepSeek
        let thirdPartySelection = activeAccount.map { provider.thirdPartySelection(forAccountID: $0.id) } ??
            CodexBarOpenRouterSelection(
                selectedModelID: provider.defaultModel,
                pinnedModelIDs: provider.defaultModel.map { [$0] } ?? []
            )
        self.store = store
        self.isEditing = true
        self.onSave = onSave
        self.onCancel = onCancel
        self._preset = State(initialValue: provider.kind == .openRouter ? .openRouter : (provider.isThirdPartyModelProvider ? .thirdParty : .custom))
        self._label = State(initialValue: provider.label)
        self._baseURL = State(initialValue: provider.baseURL ?? "")
        self._accountLabel = State(initialValue: activeAccount?.label ?? "")
        self._apiKey = State(initialValue: activeAccount?.apiKey ?? "")
        self._thirdPartyProvider = State(initialValue: thirdPartyProvider)
        self._thirdPartySelectedModelIDs = State(initialValue: Set(thirdPartySelection.pinnedModelIDs))
        self._thirdPartySelectedModelID = State(initialValue: thirdPartySelection.effectiveModelID)
        self._openRouterSelectedModelIDs = State(initialValue: Set(openRouterSelection.pinnedModelIDs))
        self._openRouterSelectedModelID = State(initialValue: openRouterSelection.effectiveModelID)
        self._openRouterCachedModels = State(initialValue: openRouterSelection.cachedModelCatalog)
        self._openRouterFetchedAt = State(initialValue: openRouterSelection.modelCatalogFetchedAt)
        self.openRouterSelectionInitialPinnedModelIDs = openRouterSelection.pinnedModelIDs
    }

    private var isOpenRouter: Bool {
        self.preset == .openRouter
    }

    private var isThirdPartyModelProvider: Bool {
        self.preset == .thirdParty
    }

    private var isCustomThirdPartyProvider: Bool {
        self.isThirdPartyModelProvider && self.thirdPartyProvider == .custom
    }

    private var canSave: Bool {
        if self.isEditing {
            if self.isOpenRouter {
                return self.openRouterSelectionPayload != nil
            }
            if self.isThirdPartyModelProvider {
                let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedAPIKey.isEmpty == false &&
                    self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                    self.orderedThirdPartySelectedModelIDs.isEmpty == false
            }
            return self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        if self.isOpenRouter {
            return true
        }

        if self.isThirdPartyModelProvider {
            return self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self.orderedThirdPartySelectedModelIDs.isEmpty == false
        }

        return self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var openRouterSelectionPayload: OpenRouterSelectionPayload? {
        makeOpenRouterSelectionPayload(
            apiKey: self.apiKey,
            selectedModelIDs: self.openRouterSelectedModelIDs,
            currentSelectedModelID: self.openRouterSelectedModelID,
            cachedModels: self.openRouterCachedModels,
            fetchedAt: self.openRouterFetchedAt
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                if self.isEditing == false {
                    AddProviderPresetControl(selection: $preset)
                }

                VStack(alignment: .leading, spacing: 18) {
                    if isOpenRouter {
                        OpenRouterKeyFormFields(apiKey: $apiKey, accountLabel: $accountLabel)
                        OpenRouterModelPickerSection(
                            store: self.store,
                            apiKey: $apiKey,
                            selectedModelIDs: $openRouterSelectedModelIDs,
                            cachedModels: $openRouterCachedModels,
                            fetchedAt: $openRouterFetchedAt,
                            initiallyPinnedModelIDs: openRouterSelectionInitialPinnedModelIDs,
                            refreshAction: { apiKey in
                                try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                            }
                        )
                    } else if isThirdPartyModelProvider {
                        AddProviderSection(title: "模型服务") {
                            if self.isEditing {
                                Text(self.thirdPartyProvider.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(height: 32, alignment: .center)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.secondary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                AddProviderThirdPartyModelControl(selection: $thirdPartyProvider)
                            }
                        }

                        if self.isCustomThirdPartyProvider {
                            ProviderFormRow(label: L.providerNameLabel) {
                                TextField(L.providerNameLabel, text: $label)
                                    .addProviderFieldChrome()
                            }
                        }

                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: $baseURL)
                                .addProviderFieldChrome()
                        }

                        if self.isEditing == false || self.isThirdPartyModelProvider {
                            ProviderFormRow(label: L.providerAPIKeyLabel) {
                                SecureField(L.providerAPIKeyLabel, text: $apiKey)
                                    .addProviderFieldChrome()
                            }

                            ProviderFormRow(label: L.providerKeyLabel) {
                                TextField(L.providerKeyLabelPlaceholder, text: $accountLabel)
                                    .addProviderFieldChrome()
                            }

                            AddProviderSection(title: "模型") {
                                ThirdPartyModelPicker(
                                    provider: self.thirdPartyProvider,
                                    selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                    selectedModelID: self.$thirdPartySelectedModelID,
                                    initialCustomModelIDs: self.orderedThirdPartySelectedModelIDs
                                )
                            }
                        }
                    } else {
                        ProviderFormRow(label: L.providerNameLabel) {
                            TextField(L.providerNamePlaceholder, text: $label)
                                .addProviderFieldChrome()
                        }

                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: $baseURL)
                                .addProviderFieldChrome()
                        }

                        if self.isEditing == false {
                            ProviderFormRow(label: L.providerAPIKeyLabel) {
                                SecureField(L.providerAPIKeyLabel, text: $apiKey)
                                    .addProviderFieldChrome()
                            }

                            ProviderFormRow(label: L.providerKeyLabel) {
                                TextField(L.providerKeyLabelPlaceholder, text: $accountLabel)
                                    .addProviderFieldChrome()
                            }
                        }
                    }
                }
                .addProviderPanel()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 18)

            Divider()

            HStack(spacing: 12) {
                Spacer()

                Button(L.cancel, action: onCancel)
                    .buttonStyle(
                        SettingsHoverButtonStyle(
                            horizontalPadding: 18,
                            verticalPadding: 7,
                            minWidth: 76,
                            minHeight: 34
                        )
                    )

                Button(self.isEditing ? L.saveProviderAction : L.addProviderAction) {
                    onSave(
                        preset,
                        label,
                        baseURL,
                        accountLabel,
                        apiKey,
                        self.isThirdPartyModelProvider ? self.thirdPartySelectionPayload : nil,
                        self.isOpenRouter ? self.openRouterSelectionPayload : nil
                    )
                }
                .buttonStyle(
                    SettingsHoverButtonStyle(
                        isPrimary: true,
                        horizontalPadding: 18,
                        verticalPadding: 7,
                        minWidth: 82,
                        minHeight: 34
                    )
                )
                .disabled(canSave == false)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: self.isOpenRouter ? 520 : (self.isThirdPartyModelProvider ? 480 : 440))
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: preset) { newValue in
            if newValue == .openRouter {
                self.label = "OpenRouter"
                self.baseURL = ""
                self.resetThirdPartyModelState()
            } else if newValue == .thirdParty {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
            } else {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.resetThirdPartyModelState()
            }
        }
        .onChange(of: thirdPartyProvider) { _ in
            self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
        }
    }

    private var orderedThirdPartySelectedModelIDs: [String] {
        let normalized = CodexBarProvider.normalizedOpenRouterModelIDs(Array(self.thirdPartySelectedModelIDs))
        let supported = self.thirdPartyProvider.supportedModels
        guard supported.isEmpty == false else {
            return normalized
        }
        let selected = Set(normalized)
        return supported.filter { selected.contains($0) }
    }

    private var thirdPartySelectionPayload: ThirdPartyModelSelectionPayload? {
        let trimmedBaseURL = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedModelIDs = self.orderedThirdPartySelectedModelIDs
        let selectedModelID = CodexBarProvider.normalizedOpenRouterModelID(self.thirdPartySelectedModelID).flatMap {
            pinnedModelIDs.contains($0) ? $0 : pinnedModelIDs.first
        }
        guard trimmedBaseURL.isEmpty == false,
              pinnedModelIDs.isEmpty == false else {
            return nil
        }
        return ThirdPartyModelSelectionPayload(
            provider: self.thirdPartyProvider,
            baseURL: trimmedBaseURL,
            selectedModelID: selectedModelID,
            pinnedModelIDs: pinnedModelIDs
        )
    }

    private func applyThirdPartyDefaultsIfNeeded(forceLabel: Bool, forceBaseURL: Bool = false) {
        if forceLabel {
            self.label = self.thirdPartyProvider.title
        }
        if forceBaseURL || self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.baseURL = self.thirdPartyProvider.defaultBaseURL
        }
        let supportedModels = self.thirdPartyProvider.supportedModels
        if supportedModels.isEmpty {
            self.thirdPartySelectedModelIDs = []
            self.thirdPartySelectedModelID = nil
        } else {
            let retained = self.thirdPartySelectedModelIDs.intersection(Set(supportedModels))
            if retained.isEmpty {
                self.thirdPartySelectedModelIDs = [self.thirdPartyProvider.defaultModel]
                self.thirdPartySelectedModelID = self.thirdPartyProvider.defaultModel
            } else {
                self.thirdPartySelectedModelIDs = retained
                if let current = self.thirdPartySelectedModelID,
                   retained.contains(current) {
                    return
                }
                self.thirdPartySelectedModelID = self.orderedThirdPartySelectedModelIDs.first
            }
        }
    }

    private func resetThirdPartyModelState() {
        self.thirdPartyProvider = .deepSeek
        self.thirdPartySelectedModelIDs = [CodexBarThirdPartyModelProvider.deepSeek.defaultModel]
        self.thirdPartySelectedModelID = CodexBarThirdPartyModelProvider.deepSeek.defaultModel
    }
}

struct OpenRouterKeyFormFields: View {
    @Binding var apiKey: String
    @Binding var accountLabel: String

    var body: some View {
        ProviderFormRow(label: L.providerAPIKeyLabel) {
            SecureField(L.providerAPIKeyLabel, text: $apiKey)
                .addProviderFieldChrome()
        }
        ProviderFormRow(label: L.openRouterKeyLabelOptional) {
            TextField(L.openRouterKeyLabelPlaceholder, text: $accountLabel)
                .addProviderFieldChrome()
        }
    }
}

struct ProviderFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(SettingsTypography.sectionHint)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct AddProviderSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(SettingsTypography.sectionHint)
                .foregroundStyle(.secondary)

            self.content
        }
    }
}

private struct AddProviderPresetControl: View {
    @Binding var selection: AddProviderPreset

    var body: some View {
        AddProviderSegmentedControl(
            items: AddProviderPreset.allCases,
            selection: self.$selection,
            title: \.title
        )
    }
}

private struct AddProviderThirdPartyModelControl: View {
    @Binding var selection: CodexBarThirdPartyModelProvider

    var body: some View {
        AddProviderSegmentedControl(
            items: CodexBarThirdPartyModelProvider.allCases,
            selection: self.$selection,
            title: \.title
        )
    }
}

private struct AddProviderSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(self.items, id: \.self) { item in
                Button {
                    self.selection = item
                } label: {
                    Text(self.title(item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundColor(self.selection == item ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(self.selection == item ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct AddProviderMenuPicker<SelectionValue: Hashable, Content: View, Label: View>: View {
    @Binding var selection: SelectionValue
    let content: Content
    let label: Label

    init(
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self._selection = selection
        self.content = content()
        self.label = label()
    }

    var body: some View {
        Picker(selection: self.$selection) {
            self.content
        } label: {
            HStack(spacing: 10) {
                self.label
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .addProviderFieldFrame()
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct ThirdPartyModelPicker: View {
    let provider: CodexBarThirdPartyModelProvider
    @Binding var selectedModelIDs: Set<String>
    @Binding var selectedModelID: String?
    @State private var customModelID = ""
    @State private var customModelIDs: [String] = []

    init(
        provider: CodexBarThirdPartyModelProvider,
        selectedModelIDs: Binding<Set<String>>,
        selectedModelID: Binding<String?>,
        initialCustomModelIDs: [String] = []
    ) {
        self.provider = provider
        self._selectedModelIDs = selectedModelIDs
        self._selectedModelID = selectedModelID
        self._customModelIDs = State(initialValue: CodexBarProvider.normalizedOpenRouterModelIDs(initialCustomModelIDs))
    }

    private var modelOptions: [String] {
        if self.provider.supportedModels.isEmpty {
            return CodexBarProvider.normalizedOpenRouterModelIDs(self.customModelIDs)
        }
        return self.provider.supportedModels
    }

    private var canAddCustomModel: Bool {
        guard self.provider.supportedModels.isEmpty,
              let normalized = CodexBarProvider.normalizedOpenRouterModelID(self.customModelID) else {
            return false
        }
        return self.modelOptions.contains(normalized) == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.provider.supportedModels.isEmpty {
                HStack(spacing: 8) {
                    TextField(L.thirdPartyModelIDPlaceholder, text: self.$customModelID)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .onSubmit {
                            self.addCustomModel()
                        }

                    Spacer(minLength: 8)

                    Button {
                        self.addCustomModel()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(self.canAddCustomModel == false)
                    .foregroundColor(self.canAddCustomModel ? .white : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(self.canAddCustomModel ? Color.accentColor : Color.secondary.opacity(0.12))
                    )
                    .help(L.thirdPartyAddModelAction)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(self.modelOptions, id: \.self) { modelID in
                    self.modelRow(modelID)
                    if modelID != self.modelOptions.last {
                        Divider().opacity(0.45)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .onAppear {
            self.ensureSelection()
        }
        .onChange(of: self.provider) { _ in
            self.customModelID = ""
            self.customModelIDs = []
            if self.provider.supportedModels.isEmpty {
                self.selectedModelIDs = []
                self.selectedModelID = nil
            }
            self.ensureSelection()
        }
    }

    private func modelRow(_ modelID: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: self.bindingForModel(modelID))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Text(modelID)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if self.selectedModelID == modelID {
                Text(L.thirdPartyCurrentModel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
            } else if self.selectedModelIDs.contains(modelID) {
                Button(L.thirdPartySetCurrentModel) {
                    self.selectedModelID = modelID
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            if self.selectedModelIDs.contains(modelID) {
                self.selectedModelIDs.remove(modelID)
                if self.selectedModelID == modelID {
                    self.selectedModelID = self.orderedSelectedModelIDs.first
                }
            } else {
                self.selectedModelIDs.insert(modelID)
                self.selectedModelID = self.selectedModelID ?? modelID
            }
        }
        .contextMenu {
            if self.provider.supportedModels.isEmpty {
                Button(role: .destructive) {
                    self.deleteCustomModel(modelID)
                } label: {
                    Label(L.thirdPartyDeleteModelAction, systemImage: "trash")
                }
            }
        }
    }

    private var orderedSelectedModelIDs: [String] {
        let selected = Set(CodexBarProvider.normalizedOpenRouterModelIDs(Array(self.selectedModelIDs)))
        let options = self.modelOptions
        if options.isEmpty {
            return []
        }
        return options.filter { selected.contains($0) }
    }

    private func bindingForModel(_ modelID: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedModelIDs.contains(modelID) },
            set: { isSelected in
                if isSelected {
                    self.selectedModelIDs.insert(modelID)
                    self.selectedModelID = self.selectedModelID ?? modelID
                } else {
                    self.selectedModelIDs.remove(modelID)
                    if self.selectedModelID == modelID {
                        self.selectedModelID = self.orderedSelectedModelIDs.first
                    }
                }
            }
        )
    }

    private func ensureSelection() {
        if self.provider.supportedModels.isEmpty {
            self.customModelIDs = self.orderedModelIDs(from: self.customModelIDs)
            self.selectedModelIDs = self.selectedModelIDs.intersection(Set(self.customModelIDs))
        } else if self.selectedModelIDs.isEmpty,
                  self.provider.defaultModel.isEmpty == false {
            self.selectedModelIDs = [self.provider.defaultModel]
        }
        if let selectedModelID,
           self.selectedModelIDs.contains(selectedModelID) {
            return
        }
        self.selectedModelID = self.orderedSelectedModelIDs.first
    }

    private func addCustomModel() {
        guard let normalized = CodexBarProvider.normalizedOpenRouterModelID(self.customModelID),
              self.modelOptions.contains(normalized) == false else {
            return
        }
        self.customModelIDs.append(normalized)
        self.selectedModelIDs.insert(normalized)
        self.selectedModelID = self.selectedModelID ?? normalized
        self.customModelID = ""
    }

    private func deleteCustomModel(_ modelID: String) {
        self.customModelIDs.removeAll { $0 == modelID }
        self.selectedModelIDs.remove(modelID)
        if self.selectedModelID == modelID {
            self.selectedModelID = self.orderedSelectedModelIDs.first
        }
    }

    private func orderedModelIDs(from values: [String]) -> [String] {
        var seen: Set<String> = []
        return CodexBarProvider.normalizedOpenRouterModelIDs(values).filter { seen.insert($0).inserted }
    }
}

extension View {
    func addProviderPanel() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
    }

    func addProviderFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .addProviderFieldFrame()
    }

    func addProviderFieldFrame() -> some View {
        self
            .padding(.horizontal, 12)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

struct AddProviderAccountSheet: View {
    let provider: CodexBarProvider
    let account: CodexBarProviderAccount?
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var label = ""
    @State private var apiKey = ""

    init(
        provider: CodexBarProvider,
        account: CodexBarProviderAccount? = nil,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.account = account
        self.onSave = onSave
        self.onCancel = onCancel
        self._label = State(initialValue: account?.label ?? "")
        self._apiKey = State(initialValue: account?.apiKey ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text(provider.label)
                    .font(SettingsTypography.sectionTitle)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 18) {
                    ProviderFormRow(label: L.providerAPIKeyLabel) {
                        SecureField(L.providerAPIKeyLabel, text: $apiKey)
                            .addProviderFieldChrome()
                    }

                    ProviderFormRow(label: L.providerKeyLabel) {
                        TextField(L.providerKeyLabelPlaceholder, text: $label)
                            .addProviderFieldChrome()
                    }
                }
                .addProviderPanel()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 20)

            Divider()

            HStack(spacing: 12) {
                Spacer()

                Button(L.cancel, action: onCancel)
                    .buttonStyle(
                        SettingsHoverButtonStyle(
                            horizontalPadding: 18,
                            verticalPadding: 7,
                            minWidth: 76,
                            minHeight: 34
                        )
                    )

                Button(L.saveProviderAction) {
                    onSave(label, apiKey)
                }
                .buttonStyle(
                    SettingsHoverButtonStyle(
                        isPrimary: true,
                        horizontalPadding: 18,
                        verticalPadding: 7,
                        minWidth: 82,
                        minHeight: 34
                    )
                )
                .disabled(self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
