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
            return "API Key"
        case .thirdParty:
            return "第三方模型"
        case .openCode:
            return "OpenCode"
        case .openRouter:
            return "OpenRouter"
        }
    }

    static var selectableCases: [AddProviderPreset] {
        [.custom, .openCode, .openRouter]
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
    @State private var lastAutoProviderLabel: String
    @State private var baseURL = ""
    @State private var accountLabel = ""
    @State private var apiKey = ""
    @State private var thirdPartyProvider: CodexBarThirdPartyModelProvider
    @State private var openCodePlan: CodexBarOpenCodePlan
    @State private var openCodeModels: [OpenCodeModel]
    @State private var openCodeFetchedAt: Date?
    @State private var isDetectingOpenCodePlan = false
    @State private var openCodePlanDetectionError: String?
    @State private var openCodeDetectionTask: Task<Void, Never>? = nil
    @State private var didDetectOpenCodePlan = false
    @State private var thirdPartySelectedModelIDs: Set<String>
    @State private var thirdPartySelectedModelID: String?
    @State private var cachedModelCatalog: [CodexBarOpenRouterModel]
    @State private var modelCatalogFetchedAt: Date?
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
        self._cachedModelCatalog = State(initialValue: store.cachedMainstreamModelCatalog())
        self._modelCatalogFetchedAt = State(initialValue: nil)
        self._openRouterSelectedModelIDs = State(initialValue: [])
        self._openRouterSelectedModelID = State(initialValue: nil)
        self._openRouterCachedModels = State(initialValue: [])
        self._openRouterFetchedAt = State(initialValue: nil)
        self._lastAutoProviderLabel = State(initialValue: "")
        self.openRouterSelectionInitialPinnedModelIDs = []
        if defaultPreset == .openRouter {
            self._baseURL = State(initialValue: Self.openRouterBaseURL)
            self._label = State(initialValue: "OpenRouter")
            self._lastAutoProviderLabel = State(initialValue: "OpenRouter")
        } else if defaultPreset == .openCode {
            self._baseURL = State(initialValue: CodexBarOpenCodePlan.go.defaultBaseURL)
            self._label = State(initialValue: CodexBarOpenCodePlan.go.title)
            self._lastAutoProviderLabel = State(initialValue: CodexBarOpenCodePlan.go.title)
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
            self._lastAutoProviderLabel = State(
                initialValue: CodexBarProvider.providerName(
                    fromBaseURL: CodexBarThirdPartyModelProvider.deepSeek.defaultBaseURL
                )
            )
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
        self._lastAutoProviderLabel = State(
            initialValue: CodexBarProvider.providerName(fromBaseURL: provider.baseURL)
        )
        self._accountLabel = State(initialValue: activeAccount?.label ?? "")
        self._apiKey = State(initialValue: activeAccount?.apiKey ?? "")
        self._thirdPartyProvider = State(initialValue: thirdPartyProvider)
        self._openCodePlan = State(initialValue: provider.effectiveOpenCodePlan ?? .go)
        let openCodeCache = provider.effectiveOpenCodePlan.flatMap {
            store.cachedOpenCodeModelCatalog(plan: $0)
        }
        self._openCodeModels = State(initialValue: openCodeCache?.models ?? [])
        self._openCodeFetchedAt = State(initialValue: openCodeCache?.fetchedAt)
        self._didDetectOpenCodePlan = State(initialValue: provider.isOpenCodeProvider)
        self._thirdPartySelectedModelIDs = State(initialValue: Set(thirdPartySelection.pinnedModelIDs))
        self._thirdPartySelectedModelID = State(initialValue: thirdPartySelection.effectiveModelID)
        self._cachedModelCatalog = State(initialValue: CodexBarConfig.uniqueOpenRouterModelCatalog(
            thirdPartySelection.cachedModelCatalog + store.cachedMainstreamModelCatalog()
        ))
        self._modelCatalogFetchedAt = State(initialValue: thirdPartySelection.modelCatalogFetchedAt)
        self._openRouterSelectedModelIDs = State(initialValue: Set(openRouterSelection.pinnedModelIDs))
        self._openRouterSelectedModelID = State(initialValue: openRouterSelection.effectiveModelID)
        self._openRouterCachedModels = State(initialValue: openRouterSelection.cachedModelCatalog)
        self._openRouterFetchedAt = State(initialValue: openRouterSelection.modelCatalogFetchedAt)
        self.openRouterSelectionInitialPinnedModelIDs = openRouterSelection.pinnedModelIDs
    }

    private var isOpenRouter: Bool {
        self.preset == .openRouter
    }

    private static let openRouterBaseURL = "https://openrouter.ai/api/v1"

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
        guard self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if self.editsProviderOnly {
            return !self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if self.isOpenRouter { return self.openRouterSelectionPayload?.selectedModelID != nil }
        if self.isOpenCode && self.isEditing == false && self.didDetectOpenCodePlan == false {
            return false
        }
        guard !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let current = self.thirdPartySelectedModelID,
              self.thirdPartySelectedModelIDs.contains(current) else { return false }
        return true
    }

    private func updateProviderNameFromBaseURL(force: Bool = false) {
        let derived = CodexBarProvider.providerName(fromBaseURL: self.baseURL)
        let current = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || current.isEmpty || current == self.lastAutoProviderLabel {
            self.label = derived
        }
        self.lastAutoProviderLabel = derived
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
                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: self.$baseURL).addProviderFieldChrome()
                        }
                        if self.preset == .custom {
                            ProviderFormRow(label: L.providerNameLabel) {
                                TextField(L.providerNameLabel, text: self.$label)
                                    .addProviderFieldChrome()
                            }
                        }
                    } else {
                        ProviderFormRow(label: L.providerBaseURLLabel) {
                            TextField(L.providerBaseURLLabel, text: $baseURL)
                                .addProviderFieldChrome()
                                .disabled(self.isOpenRouter || self.isOpenCode)
                        }

                        ProviderFormRow(label: L.providerAPIKeyLabel) {
                            SecureField(L.providerAPIKeyLabel, text: $apiKey)
                                .addProviderFieldChrome()
                        }

                        if self.preset == .custom {
                            ProviderFormRow(label: L.providerNameLabel) {
                                TextField(L.providerNamePlaceholder, text: self.$label)
                                    .addProviderFieldChrome()
                            }
                        }

                        if self.isOpenCode {
                            HStack(spacing: AddProviderFormMetrics.rowSpacing) {
                                Text(L.zh ? "服务检测" : "Service")
                                    .font(SettingsTypography.sectionHint)
                                    .frame(width: AddProviderFormMetrics.labelWidth, alignment: .leading)
                                Group {
                                    if self.isDetectingOpenCodePlan {
                                        Text(L.openCodeDetectingPlan)
                                    } else if let error = self.openCodePlanDetectionError {
                                        Text(error).foregroundColor(.red)
                                    } else if self.didDetectOpenCodePlan {
                                        Text(self.openCodePlan.title)
                                    } else {
                                        Text(L.zh ? "输入 API Key 后自动检测" : "Detected automatically after entering an API key")
                                    }
                                }
                                .font(SettingsTypography.sectionHint)
                                .foregroundColor(SettingsPalette.secondaryText)
                            }
                        } else if self.isThirdPartyModelProvider {
                            ProviderFormRow(label: L.zh ? "模型服务" : "Model service") {
                                if self.isEditing {
                                    Text(self.thirdPartyProvider.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .addProviderFieldFrame()
                                } else {
                                    AddProviderThirdPartyModelControl(selection: self.$thirdPartyProvider)
                                }
                            }
                        }

                        ProviderFormRow(label: L.providerKeyLabel) {
                            TextField(L.providerKeyLabelPlaceholder, text: $accountLabel)
                                .addProviderFieldChrome()
                        }

                        if self.isOpenRouter {
                            OpenRouterModelPickerSection(
                                store: self.store,
                                apiKey: $apiKey,
                                selectedModelIDs: $openRouterSelectedModelIDs,
                                selectedModelID: $openRouterSelectedModelID,
                                cachedModels: $openRouterCachedModels,
                                fetchedAt: $openRouterFetchedAt,
                                initiallyPinnedModelIDs: openRouterSelectionInitialPinnedModelIDs,
                                refreshAction: { apiKey in
                                    try await self.store.previewOpenRouterModelCatalog(apiKey: apiKey)
                                }
                            )
                        } else if self.isOpenCode {
                            OpenCodeModelPickerSection(
                                plan: self.openCodePlan,
                                apiKey: self.$apiKey,
                                selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                selectedModelID: self.$thirdPartySelectedModelID,
                                models: self.$openCodeModels,
                                fetchedAt: self.$openCodeFetchedAt,
                                refreshAction: { plan, apiKey in
                                    try await self.store.previewOpenCodeModelCatalog(plan: plan, apiKey: apiKey)
                                },
                                refreshEnabled: self.isEditing || self.didDetectOpenCodePlan
                            )
                        } else {
                            ThirdPartyModelPicker(
                                provider: self.isThirdPartyModelProvider ? self.thirdPartyProvider : .custom,
                                selectedModelIDs: self.$thirdPartySelectedModelIDs,
                                selectedModelID: self.$thirdPartySelectedModelID,
                                initialCustomModelIDs: self.orderedThirdPartySelectedModelIDs,
                                cachedModelCatalog: self.$cachedModelCatalog,
                                refreshCatalog: nil
                            )
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
        .frame(width: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: preset) { newValue in
            self.openCodeDetectionTask?.cancel()
            self.openCodePlanDetectionError = nil
            self.didDetectOpenCodePlan = false
            if newValue == .openRouter {
                self.baseURL = Self.openRouterBaseURL
                self.label = "OpenRouter"
                self.resetThirdPartyModelState()
            } else if newValue == .openCode {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.openCodePlan = .go
                self.baseURL = self.openCodePlan.defaultBaseURL
                self.label = self.openCodePlan.title
                self.thirdPartyProvider = .openCode
                let cached = self.store.cachedOpenCodeModelCatalog(plan: .go)
                self.openCodeModels = cached?.models ?? []
                self.openCodeFetchedAt = cached?.fetchedAt
                self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
            } else if newValue == .thirdParty {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.thirdPartyProvider = .deepSeek
                self.baseURL = self.thirdPartyProvider.defaultBaseURL
                self.label = self.thirdPartyProvider.title
                self.applyThirdPartyDefaultsIfNeeded(forceLabel: true, forceBaseURL: true)
            } else {
                self.apiKey = ""
                self.accountLabel = ""
                self.openRouterSelectedModelIDs = []
                self.openRouterSelectedModelID = nil
                self.baseURL = ""
                self.updateProviderNameFromBaseURL(force: true)
                self.resetThirdPartyModelState()
            }
        }
        .onChange(of: baseURL) { newValue in
            if self.preset == .custom {
                self.updateProviderNameFromBaseURL()
            }
            if self.isOpenCode,
               let inferredPlan = CodexBarOpenCodePlan.inferred(from: newValue),
               inferredPlan != self.openCodePlan {
                self.openCodePlan = inferredPlan
            }
        }
        .onChange(of: apiKey) { _ in
            self.scheduleOpenCodePlanDetection()
        }
        .onChange(of: thirdPartyProvider) { _ in
            guard self.usesThirdPartyPayload else { return }
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
        .onDisappear {
            self.openCodeDetectionTask?.cancel()
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
            let catalogIDs = self.cachedModelCatalog.map(\.id)
            let selected = Set(normalized)
            return catalogIDs.filter { selected.contains($0) } + normalized.filter { catalogIDs.contains($0) == false }
        }
        let selected = Set(normalized)
        return supported.filter { selected.contains($0) } + normalized.filter { !supported.contains($0) }
    }

    private var customKeyPayload: ThirdPartyModelSelectionPayload? {
        guard let model = self.thirdPartySelectedModelID, self.thirdPartySelectedModelIDs.contains(model) else { return nil }
        return .init(provider: .custom, baseURL: self.baseURL, selectedModelID: model,
            pinnedModelIDs: self.orderedThirdPartySelectedModelIDs, openCodePlan: nil,
            cachedModelCatalog: self.cachedModelCatalog, fetchedAt: self.modelCatalogFetchedAt)
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
            cachedModelCatalog: self.isOpenCode
                ? self.openCodeModels.map(\.selectionModel)
                : self.cachedModelCatalog,
            fetchedAt: self.isOpenCode ? self.openCodeFetchedAt : self.modelCatalogFetchedAt
        )
    }

    private func scheduleOpenCodePlanDetection() {
        self.openCodeDetectionTask?.cancel()
        guard self.isOpenCode, self.isEditing == false else { return }
        let key = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8 else {
            self.openCodePlanDetectionError = nil
            self.didDetectOpenCodePlan = false
            return
        }

        self.openCodeDetectionTask = Task {
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            await self.detectOpenCodePlan()
        }
    }

    @MainActor
    private func detectOpenCodePlan() async {
        let key = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else { return }
        self.isDetectingOpenCodePlan = true
        self.openCodePlanDetectionError = nil
        self.didDetectOpenCodePlan = false
        defer { self.isDetectingOpenCodePlan = false }
        do {
            let plan = try await self.store.detectOpenCodePlan(apiKey: key)
            self.openCodePlan = plan
            self.didDetectOpenCodePlan = true
            self.label = plan.title
            self.baseURL = plan.defaultBaseURL
            self.openCodeModels = self.store.cachedOpenCodeModelCatalog(plan: plan)?.models ?? []
            self.openCodeFetchedAt = self.store.cachedOpenCodeModelCatalog(plan: plan)?.fetchedAt
            self.thirdPartySelectedModelIDs = []
            self.thirdPartySelectedModelID = nil
            self.applyThirdPartyDefaultsIfNeeded(forceLabel: false, forceBaseURL: true)
        } catch {
            guard Task.isCancelled == false else { return }
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
        self.cachedModelCatalog = self.store.cachedMainstreamModelCatalog()
        self.modelCatalogFetchedAt = nil
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
        HStack(alignment: .center, spacing: AddProviderFormMetrics.rowSpacing) {
            Text(label)
                .font(SettingsTypography.sectionHint)
                .foregroundStyle(.secondary)
                .frame(width: AddProviderFormMetrics.labelWidth, alignment: .leading)
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
            items: AddProviderPreset.selectableCases,
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
    @Binding var cachedModelCatalog: [CodexBarOpenRouterModel]
    let refreshCatalog: (() -> [CodexBarOpenRouterModel])?
    @State private var additionalModelIDs: [String]

    init(
        provider: CodexBarThirdPartyModelProvider,
        selectedModelIDs: Binding<Set<String>>,
        selectedModelID: Binding<String?>,
        initialCustomModelIDs: [String] = [],
        cachedModelCatalog: Binding<[CodexBarOpenRouterModel]>,
        refreshCatalog: (() -> [CodexBarOpenRouterModel])? = nil
    ) {
        self.provider = provider
        self._selectedModelIDs = selectedModelIDs
        self._selectedModelID = selectedModelID
        self._cachedModelCatalog = cachedModelCatalog
        self.refreshCatalog = refreshCatalog
        self._additionalModelIDs = State(
            initialValue: CodexBarProvider.normalizedOpenRouterModelIDs(initialCustomModelIDs)
        )
    }

    private var catalogModels: [CodexBarOpenRouterModel] {
        if self.provider.supportedModels.isEmpty {
            return self.cachedModelCatalog
        }
        let catalogByID = Dictionary(
            self.cachedModelCatalog.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return self.provider.supportedModels.map { catalogByID[$0] ?? CodexBarOpenRouterModel(id: $0) }
    }

    private var pickerModels: [ProviderModelPickerItem] {
        let models = CodexBarConfig.uniqueOpenRouterModelCatalog(
            self.catalogModels + self.additionalModelIDs.map { CodexBarOpenRouterModel(id: $0) }
        )
        return models.map {
            ProviderModelPickerItem(id: $0.id, name: $0.name, context: nil)
        }
    }

    var body: some View {
        let refreshAction: (() async throws -> Void)? = self.refreshCatalog.map { refreshCatalog in
            {
                let selectedModels = self.cachedModelCatalog.filter {
                    self.selectedModelIDs.contains($0.id)
                }
                self.cachedModelCatalog = CodexBarConfig.uniqueOpenRouterModelCatalog(
                    refreshCatalog() + selectedModels
                )
            }
        }
        return ProviderModelPickerSection(
            selectedModelIDs: self.$selectedModelIDs,
            selectedModelID: self.$selectedModelID,
            models: self.pickerModels,
            emptyMessage: L.openRouterModelPickerNoCache,
            refreshEnabled: self.refreshCatalog != nil,
            refreshAction: refreshAction
        )
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
    @State private var cachedModelCatalog: [CodexBarOpenRouterModel]
    @State private var modelCatalogFetchedAt: Date?

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
        self._cachedModelCatalog = State(initialValue: CodexBarConfig.uniqueOpenRouterModelCatalog(
            (account?.modelSelection?.cachedModelCatalog ?? []) + TokenStore.builtInCachedMainstreamModels
        ))
        self._modelCatalogFetchedAt = State(initialValue: account?.modelSelection?.modelCatalogFetchedAt)
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
                    ThirdPartyModelPicker(
                        provider: .custom,
                        selectedModelIDs: self.$models,
                        selectedModelID: self.$currentModel,
                        initialCustomModelIDs: Array(self.models),
                        cachedModelCatalog: self.$cachedModelCatalog
                    )
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
                    if let selected = self.currentModel {
                        onSave(
                            label,
                            apiKey,
                            .init(
                                selectedModelID: selected,
                                pinnedModelIDs: Array(self.models).sorted(),
                                cachedModelCatalog: self.cachedModelCatalog,
                                modelCatalogFetchedAt: self.modelCatalogFetchedAt
                            )
                        )
                    }
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
