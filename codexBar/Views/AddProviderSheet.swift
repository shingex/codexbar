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
    let modelID: String
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
    @State private var thirdPartyModelID = ""
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
        self._thirdPartyModelID = State(initialValue: CodexBarThirdPartyModelProvider.deepSeek.defaultModel)
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
        let activeAccount = provider.activeAccount
        let openRouterSelection = activeAccount.map { provider.openRouterSelection(forAccountID: $0.id) } ??
            provider.openRouterProviderLevelSelection
        let thirdPartyProvider = provider.thirdPartyModelProvider ?? .deepSeek
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
        self._thirdPartyModelID = State(initialValue: provider.defaultModel ?? thirdPartyProvider.defaultModel)
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
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return false }

        if self.isOpenRouter {
            return true
        }

        if self.isThirdPartyModelProvider {
            return self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                self.thirdPartyModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
        VStack(alignment: .leading, spacing: 12) {
            if self.isEditing == false {
                Picker("Preset", selection: $preset) {
                    ForEach(AddProviderPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

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
                ProviderFormRow(label: "模型服务") {
                    Picker("模型服务", selection: $thirdPartyProvider) {
                        ForEach(CodexBarThirdPartyModelProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if self.isCustomThirdPartyProvider {
                    ProviderFormRow(label: L.providerNameLabel) {
                        TextField(L.providerNameLabel, text: $label)
                    }
                }
                ProviderFormRow(label: L.providerBaseURLLabel) {
                    TextField(L.providerBaseURLLabel, text: $baseURL)
                }
                ProviderFormRow(label: "模型") {
                    if thirdPartyProvider.supportedModels.isEmpty {
                        TextField("模型", text: $thirdPartyModelID)
                    } else {
                        Picker("模型", selection: $thirdPartyModelID) {
                            ForEach(thirdPartyProvider.supportedModels, id: \.self) { modelID in
                                Text(modelID).tag(modelID)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                ProviderFormRow(label: L.providerAccountLabel) {
                    TextField(L.providerAccountLabel, text: $accountLabel)
                }
                ProviderFormRow(label: L.providerAPIKeyLabel) {
                    SecureField(L.providerAPIKeyLabel, text: $apiKey)
                }
            } else {
                ProviderFormRow(label: L.providerNameLabel) {
                    TextField(L.providerNameLabel, text: $label)
                }
                ProviderFormRow(label: L.providerBaseURLLabel) {
                    TextField(L.providerBaseURLLabel, text: $baseURL)
                }
                ProviderFormRow(label: L.providerAccountLabel) {
                    TextField(L.providerAccountLabel, text: $accountLabel)
                }
                ProviderFormRow(label: L.providerAPIKeyLabel) {
                    SecureField(L.providerAPIKeyLabel, text: $apiKey)
                }
            }

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
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
                .buttonStyle(.borderedProminent)
                .disabled(canSave == false)
            }
        }
        .padding(16)
        .frame(width: self.isOpenRouter ? 460 : (self.isThirdPartyModelProvider ? 400 : 360))
        .onChange(of: preset) { newValue in
            if newValue == .openRouter {
                self.label = "OpenRouter"
                self.baseURL = ""
            } else if newValue == .thirdParty {
                self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
            }
        }
        .onChange(of: thirdPartyProvider) { _ in
            self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
        }
    }

    private var thirdPartySelectionPayload: ThirdPartyModelSelectionPayload? {
        let trimmedBaseURL = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = self.thirdPartyModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBaseURL.isEmpty == false,
              trimmedModelID.isEmpty == false else {
            return nil
        }
        return ThirdPartyModelSelectionPayload(
            provider: self.thirdPartyProvider,
            baseURL: trimmedBaseURL,
            modelID: trimmedModelID
        )
    }

    private func applyThirdPartyDefaultsIfNeeded(forceLabel: Bool, forceBaseURL: Bool = false) {
        if forceLabel {
            self.label = self.thirdPartyProvider.title
        }
        if forceBaseURL || self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.baseURL = self.thirdPartyProvider.defaultBaseURL
        }
        if self.thirdPartyProvider.supportedModels.isEmpty {
            if forceBaseURL || self.thirdPartyModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.thirdPartyModelID = self.thirdPartyProvider.defaultModel
            }
        } else if self.thirdPartyProvider.supportedModels.contains(self.thirdPartyModelID) == false {
            self.thirdPartyModelID = self.thirdPartyProvider.defaultModel
        }
    }
}

struct OpenRouterKeyFormFields: View {
    @Binding var apiKey: String
    @Binding var accountLabel: String

    var body: some View {
        ProviderFormRow(label: L.providerAPIKeyLabel) {
            SecureField(L.providerAPIKeyLabel, text: $apiKey)
        }
        ProviderFormRow(label: L.openRouterKeyLabelOptional) {
            TextField(L.openRouterKeyLabelPlaceholder, text: $accountLabel)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
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
        VStack(alignment: .leading, spacing: 12) {
            Text("\(account == nil ? L.addProviderAccountTitle : L.editProviderAccountTitle) · \(provider.label)")
                .font(.headline)

            TextField(L.providerAccountLabel, text: $label)
            SecureField(L.providerAPIKeyLabel, text: $apiKey)

            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                Button(L.saveProviderAction) {
                    onSave(label, apiKey)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
