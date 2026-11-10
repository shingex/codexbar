import SwiftUI

enum AddProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case thirdParty
    case openCode
    case openRouter

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .custom:
            return "OpenAI中转"
        case .thirdParty:
            return "第三方模型"
        case .openCode:
            return "OpenCode"
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
    let openCodePlan: CodexBarOpenCodePlan?
    let cachedModelCatalog: [CodexBarOpenRouterModel]
    let fetchedAt: Date?
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
    @State private var openCodePlan: CodexBarOpenCodePlan
    @State private var openCodeModels: [OpenCodeModel]
    @State private var openCodeFetchedAt: Date?
    @State private var isDetectingOpenCodePlan = false
    @State private var openCodePlanDetectionError: String?
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
    private let editsProviderOnly: Bool

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
        self.editsProviderOnly = false
        self.isEditing = false
        self.onSave = onSave
        self.onCancel = onCancel
        self._thirdPartyProvider = State(initialValue: .deepSeek)
        self._openCodePlan = State(initialValue: .go)
        self._openCodeModels = State(initialValue: [])
        self._openCodeFetchedAt = State(initialValue: nil)
        self._thirdPartySelectedModelIDs = State(initialValue: defaultPreset == .custom ? [] : [CodexBarThirdPartyModelProvider.deepSeek.defaultModel])
        self._thirdPartySelectedModelID = State(initialValue: defaultPreset == .custom ? nil : CodexBarThirdPartyModelProvider.deepSeek.defaultModel)
        self._openRouterSelectedModelIDs = State(initialValue: [])
        self._openRouterSelectedModelID = State(initialValue: nil)
        self._openRouterCachedModels = State(initialValue: [])
        self._openRouterFetchedAt = State(initialValue: nil)
        self.openRouterSelectionInitialPinnedModelIDs = []
        if defaultPreset == .openRouter {
            self._label = State(initialValue: "OpenRouter")
        } else if defaultPreset == .openCode {
            self._label = State(initialValue: CodexBarOpenCodePlan.go.title)
            self._baseURL = State(initialValue: CodexBarOpenCodePlan.go.defaultBaseURL)
            self._thirdPartyProvider = State(initialValue: .openCode)
            self._openCodePlan = State(initialValue: .go)
            let cached = store.cachedOpenCodeModelCatalog(plan: .go)
            self._openCodeModels = State(initialValue: cached?.models ?? [])
            self._openCodeFetchedAt = State(initialValue: cached?.fetchedAt)
            self._thirdPartySelectedModelIDs = State(initialValue: [CodexBarOpenCodePlan.go.defaultModel])
            self._thirdPartySelectedModelID = State(initialValue: CodexBarOpenCodePlan.go.defaultModel)
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
        let openRouterSelection = activeAccount?.modelSelection ?? CodexBarKeyModelSelection()
        let thirdPartyProvider = provider.thirdPartyModelProvider ?? .custom
        let thirdPartySelection = activeAccount?.modelSelection ?? CodexBarKeyModelSelection()
        self.store = store
        self.editsProviderOnly = account == nil && provider.kind != .openRouter
        self.isEditing = true
        self.onSave = onSave
        self.onCancel = onCancel
        self._preset = State(initialValue: provider.kind == .openRouter
            ? .openRouter
            : (provider.isOpenCodeProvider ? .openCode : (provider.isThirdPartyModelProvider ? .thirdParty : .custom)))
        self._label = State(initialValue: provider.label)
        self._baseURL = State(initialValue: provider.baseURL ?? "")
        self._accountLabel = State(initialValue: activeAccount?.label ?? "")
        self._apiKey = State(initialValue: activeAccount?.apiKey ?? "")
        self._thirdPartyProvider = State(initialValue: thirdPartyProvider)
        self._openCodePlan = State(initialValue: provider.effectiveOpenCodePlan ?? .go)
        let openCodeCache = provider.effectiveOpenCodePlan.flatMap {
            store.cachedOpenCodeModelCatalog(plan: $0)
        }
        self._openCodeModels = State(initialValue: openCodeCache?.models ?? [])
        self._openCodeFetchedAt = State(initialValue: openCodeCache?.fetchedAt)
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

    private var isOpenCode: Bool {
        self.preset == .openCode
    }

    private var usesThirdPartyPayload: Bool {
        self.preset == .thirdParty || self.preset == .openCode
    }

    private var isThirdPartyModelProvider: Bool {
        self.preset == .thirdParty
    }

    private var isCustomThirdPartyProvider: Bool {
        self.isThirdPartyModelProvider && self.thirdPartyProvider == .custom
    }

    private var canSave: Bool {
        if self.editsProviderOnly {
            return !self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if self.isOpenRouter { return self.openRouterSelectionPayload?.selectedModelID != nil }
        guard !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let current = self.thirdPartySelectedModelID,
              self.thirdPartySelectedModelIDs.contains(current) else { return false }
        return true
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
                    if self.editsProviderOnly {
                        ProviderFormRow(label: L.zh ? "Provider 名称（可选）" : "Provider name (optional)") {
                            TextField(L.providerNamePlaceholder, text: self.$label).addProviderFieldChrome()
                        }
                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: self.$baseURL).addProviderFieldChrome()
                        }
                    } else if isOpenRouter {
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
                        Picker(L.zh ? "请求模型" : "Request model", selection: self.$openRouterSelectedModelID) {
                            Text(L.zh ? "请选择" : "Choose a model").tag(String?.none)
                            ForEach(Array(self.openRouterSelectedModelIDs).sorted(), id: \.self) { model in
                                Text(model).tag(Optional(model))
                            }
                        }

                    } else if self.usesThirdPartyPayload {
                        AddProviderSection(title: "模型服务") {
                            if self.isEditing {
                                Text(self.isOpenCode
                                    ? (self.openCodePlan.title)
                                    : self.thirdPartyProvider.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(height: 32, alignment: .center)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.secondary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if self.isOpenCode {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        AddProviderSegmentedControl(
                                            items: CodexBarOpenCodePlan.allCases,
                                            selection: self.$openCodePlan,
                                            title: \.title
                                        )

                                        Button(self.isDetectingOpenCodePlan ? L.openCodeDetectingPlan : L.openCodeDetectPlanAction) {
                                            Task { await self.detectOpenCodePlan() }
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11, weight: .medium))
                                        .disabled(
                                            self.isDetectingOpenCodePlan ||
                                                self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        )
                                    }

                                    if let error = self.openCodePlanDetectionError {
                                        Text(error)
                                            .font(.system(size: 11))
                                            .foregroundColor(.red)
                                    }
                                }
                            } else {
                                AddProviderThirdPartyModelControl(selection: $thirdPartyProvider)
                            }
                        }

                        if self.isCustomThirdPartyProvider {
                            ProviderFormRow(label: L.zh ? "Provider 名称（可选）" : "Provider name (optional)") {
                                TextField(L.providerNameLabel, text: $label)
                                    .addProviderFieldChrome()
                            }
                        }

                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: $baseURL)
                                .addProviderFieldChrome()
                        }

                        if self.isEditing == false || self.usesThirdPartyPayload {
                            ProviderFormRow(label: L.providerAPIKeyLabel) {
                                SecureField(L.providerAPIKeyLabel, text: $apiKey)
                                    .addProviderFieldChrome()
                            }

                            ProviderFormRow(label: L.providerKeyLabel) {
                                TextField(L.providerKeyLabelPlaceholder, text: $accountLabel)
                                    .addProviderFieldChrome()
                            }

                            AddProviderSection(title: "模型") {
                                if self.isOpenCode {
                                    OpenCodeModelPickerSection(
                                        plan: self.openCodePlan,
                                        apiKey: self.$apiKey,
                                        selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                        selectedModelID: self.$thirdPartySelectedModelID,
                                        models: self.$openCodeModels,
                                        fetchedAt: self.$openCodeFetchedAt,
                                        refreshAction: { plan, apiKey in
                                            try await self.store.previewOpenCodeModelCatalog(plan: plan, apiKey: apiKey)
                                        }
                                    )
                                } else {
                                    ThirdPartyModelPicker(
                                        provider: self.thirdPartyProvider,
                                        selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                        selectedModelID: self.$thirdPartySelectedModelID,
                                        initialCustomModelIDs: self.orderedThirdPartySelectedModelIDs
                                    )
                                }
                            }
                        }
                    } else {
                        ProviderFormRow(label: L.zh ? "Provider 名称（可选）" : "Provider name (optional)") {
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
                        if !self.isEditing {
                            ThirdPartyModelPicker(provider: .custom, selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                selectedModelID: self.$thirdPartySelectedModelID)
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
                        self.isOpenCode ? self.openCodePlan.title : label,
                        baseURL,
                        accountLabel,
                        apiKey,
                        self.preset == .custom ? self.customKeyPayload : self.thirdPartySelectionPayload,
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
        .frame(width: self.isOpenRouter ? 520 : (self.usesThirdPartyPayload ? 480 : 440))
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: preset) { newValue in
            if newValue == .openRouter {
                self.label = "OpenRouter"
                self.baseURL = ""
                self.resetThirdPartyModelState()
            } else if newValue == .openCode {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.openCodePlan = .go
                self.thirdPartyProvider = .openCode
                self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
            } else if newValue == .thirdParty {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.thirdPartyProvider = .deepSeek
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
        .onChange(of: openCodePlan) { newValue in
            guard self.isOpenCode else { return }
            let cached = self.store.cachedOpenCodeModelCatalog(plan: newValue)
            self.openCodeModels = cached?.models ?? []
            self.openCodeFetchedAt = cached?.fetchedAt
            self.thirdPartySelectedModelIDs = []
            self.thirdPartySelectedModelID = nil
            self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
        }
    }

    private var orderedThirdPartySelectedModelIDs: [String] {
        let normalized = CodexBarProvider.normalizedOpenRouterModelIDs(Array(self.thirdPartySelectedModelIDs))
        if self.isOpenCode {
            let catalogIDs = self.openCodeModels.map(\.id)
            guard catalogIDs.isEmpty == false else { return normalized }
            let selected = Set(normalized)
            let ordered = catalogIDs.filter { selected.contains($0) }
            let remaining = normalized.filter { catalogIDs.contains($0) == false }
            return ordered + remaining
        }
        let supported = self.thirdPartyProvider.supportedModels
        guard supported.isEmpty == false else {
            return normalized
        }
        let selected = Set(normalized)
        return supported.filter { selected.contains($0) } + normalized.filter { !supported.contains($0) }
    }

    private var customKeyPayload: ThirdPartyModelSelectionPayload? {
        guard let model = self.thirdPartySelectedModelID, self.thirdPartySelectedModelIDs.contains(model) else { return nil }
        return .init(provider: .custom, baseURL: self.baseURL, selectedModelID: model,
            pinnedModelIDs: Array(self.thirdPartySelectedModelIDs).sorted(), openCodePlan: nil, cachedModelCatalog: [], fetchedAt: nil)
    }

    private var thirdPartySelectionPayload: ThirdPartyModelSelectionPayload? {
        let trimmedBaseURL = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedModelIDs = self.orderedThirdPartySelectedModelIDs
        let selectedModelID = CodexBarProvider.normalizedOpenRouterModelID(self.thirdPartySelectedModelID).flatMap {
            pinnedModelIDs.contains($0) ? $0 : nil
        }
        guard trimmedBaseURL.isEmpty == false,
              pinnedModelIDs.isEmpty == false else {
            return nil
        }
        return ThirdPartyModelSelectionPayload(
            provider: self.isOpenCode ? .openCode : self.thirdPartyProvider,
            baseURL: trimmedBaseURL,
            selectedModelID: selectedModelID,
            pinnedModelIDs: pinnedModelIDs,
            openCodePlan: self.isOpenCode ? self.openCodePlan : nil,
            cachedModelCatalog: self.isOpenCode ? self.openCodeModels.map(\.selectionModel) : [],
            fetchedAt: self.isOpenCode ? self.openCodeFetchedAt : nil
        )
    }

    @MainActor
    private func detectOpenCodePlan() async {
        let key = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        self.isDetectingOpenCodePlan = true
        self.openCodePlanDetectionError = nil
        defer { self.isDetectingOpenCodePlan = false }
        do {
            let plan = try await self.store.detectOpenCodePlan(apiKey: key)
            self.openCodePlan = plan
            self.openCodeModels = self.store.cachedOpenCodeModelCatalog(plan: plan)?.models ?? []
            self.openCodeFetchedAt = self.store.cachedOpenCodeModelCatalog(plan: plan)?.fetchedAt
            self.thirdPartySelectedModelIDs = []
            self.thirdPartySelectedModelID = nil
            self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
        } catch {
            self.openCodePlanDetectionError = error.localizedDescription
        }
    }

    private func applyThirdPartyDefaultsIfNeeded(forceLabel: Bool, forceBaseURL: Bool = false) {
        if self.isOpenCode {
            if forceLabel {
                self.label = self.openCodePlan.title
            }
            if forceBaseURL || self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.baseURL = self.openCodePlan.defaultBaseURL
            }
            let catalogModels = self.openCodeModels.map(\.id)
            let supportedModels = catalogModels.isEmpty
                ? CodexBarThirdPartyModelProvider.openCode.supportedModels
                : catalogModels
            let retained = self.thirdPartySelectedModelIDs.intersection(Set(supportedModels))
            if retained.isEmpty {
                let preferred = supportedModels.contains(self.openCodePlan.defaultModel)
                    ? self.openCodePlan.defaultModel
                    : (supportedModels.first ?? self.openCodePlan.defaultModel)
                self.thirdPartySelectedModelIDs = [preferred]
                self.thirdPartySelectedModelID = preferred
            } else {
                self.thirdPartySelectedModelIDs = retained
                if let current = self.thirdPartySelectedModelID, retained.contains(current) {
                    return
                }
                self.thirdPartySelectedModelID = self.orderedThirdPartySelectedModelIDs.first
            }
            return
        }

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
        self.thirdPartySelectedModelIDs = []
        self.thirdPartySelectedModelID = nil
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
            items: CodexBarThirdPartyModelProvider.genericCases,
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
        CodexBarProvider.normalizedOpenRouterModelIDs(self.provider.supportedModels + self.customModelIDs)
    }

    private var canAddCustomModel: Bool {
        guard let normalized = CodexBarProvider.normalizedOpenRouterModelID(self.customModelID) else {
            return false
        }
        return self.modelOptions.contains(normalized) == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
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
        self.customModelIDs = self.orderedModelIDs(from: self.customModelIDs + Array(self.selectedModelIDs))
        if let selectedModelID, !self.selectedModelIDs.contains(selectedModelID) {
            self.selectedModelID = nil
        }
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
    let onSave: (String, String, CodexBarKeyModelSelection) -> Void
    let onCancel: () -> Void

    @State private var label = ""
    @State private var apiKey = ""
    @State private var models: Set<String>
    @State private var currentModel: String?

    init(
        provider: CodexBarProvider,
        account: CodexBarProviderAccount? = nil,
        onSave: @escaping (String, String, CodexBarKeyModelSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.account = account
        self.onSave = onSave
        self.onCancel = onCancel
        self._models = State(initialValue: Set(account?.modelSelection?.pinnedModelIDs ?? []))
        self._currentModel = State(initialValue: account?.modelSelection?.selectedModelID)
        self._label = State(initialValue: account?.label ?? "")
        self._apiKey = State(initialValue: account?.apiKey ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text(provider.displayName)
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
                    ThirdPartyModelPicker(provider: .custom, selectedModelIDs: self.$models,
                        selectedModelID: self.$currentModel, initialCustomModelIDs: Array(self.models))
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
                    if let selected = self.currentModel { onSave(label, apiKey, .init(selectedModelID: selected, pinnedModelIDs: Array(self.models).sorted())) }
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
                .disabled((self.provider.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.currentModel == nil || !self.models.contains(self.currentModel ?? ""))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
