import SwiftUI

enum AddProviderFormMetrics {
    static let labelWidth: CGFloat = 128
    static let rowSpacing: CGFloat = 12
}

struct ProviderModelPickerItem: Identifiable, Equatable {
    let id: String
    let name: String
    let context: String?
}

struct ProviderModelPickerSection: View {
    @Binding var selectedModelIDs: Set<String>
    @Binding var selectedModelID: String?

    let models: [ProviderModelPickerItem]
    let emptyMessage: String
    let refreshEnabled: Bool
    let refreshAction: (() async throws -> Void)?

    @State private var query = ""
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    private var displayModels: [ProviderModelPickerItem] {
        let catalogIDs = Set(self.models.map(\.id))
        let selectedOnly = self.selectedModelIDs
            .filter { catalogIDs.contains($0) == false }
            .sorted()
            .map { ProviderModelPickerItem(id: $0, name: $0, context: nil) }
        var seen: Set<String> = []
        return (self.models + selectedOnly).filter { seen.insert($0.id).inserted }
    }

    private var filteredModels: [ProviderModelPickerItem] {
        let trimmedQuery = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return self.displayModels }
        return self.displayModels.filter {
            $0.id.localizedCaseInsensitiveContains(trimmedQuery) ||
                $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var canAddTypedModel: Bool {
        CodexBarProvider.normalizedOpenRouterModelID(self.query) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AddProviderFormMetrics.rowSpacing) {
                Text(L.zh ? "模型" : "Models")
                    .font(SettingsTypography.rowTitle)
                    .frame(width: AddProviderFormMetrics.labelWidth, alignment: .leading)

                Spacer(minLength: 8)

                if let refreshAction {
                    Button {
                        Task { await self.refresh(refreshAction) }
                    } label: {
                        Label(
                            self.isRefreshing ? L.openRouterModelPickerRefreshing : L.openRouterModelPickerRefresh,
                            systemImage: self.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                        )
                        .font(SettingsTypography.sectionHint)
                    }
                    .buttonStyle(SettingsHoverButtonStyle(isOutlined: true, minHeight: 28))
                    .disabled(self.isRefreshing || self.refreshEnabled == false)
                }
            }

            HStack(spacing: 8) {
                TextField(L.thirdPartyModelIDPlaceholder, text: self.$query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit { self.addTypedModel() }

                Spacer(minLength: 8)

                Button {
                    self.addTypedModel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(self.canAddTypedModel == false)
                .foregroundColor(self.canAddTypedModel ? .white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(self.canAddTypedModel ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .help(L.thirdPartyAddModelAction)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(SettingsTypography.sectionHint)
                    .foregroundColor(.red)
            }

            Group {
                if self.displayModels.isEmpty {
                    Text(self.emptyMessage)
                } else if self.filteredModels.isEmpty {
                    Text(L.openRouterModelPickerNoMatches)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(self.filteredModels) { model in
                                self.modelRow(model)
                                if model.id != self.filteredModels.last?.id {
                                    Divider().opacity(0.45)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.45))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: ProviderModelPickerItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: self.bindingForModel(model.id))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if model.name != model.id {
                    Text(model.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let context = model.context {
                Text(context)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            self.toggleModel(model.id)
        }
    }

    private func bindingForModel(_ modelID: String) -> Binding<Bool> {
        Binding(
            get: { self.selectedModelIDs.contains(modelID) },
            set: { isSelected in
                if isSelected {
                    self.selectedModelIDs.insert(modelID)
                    if self.selectedModelID == nil {
                        self.selectedModelID = modelID
                    }
                } else {
                    self.removeModel(modelID)
                }
            }
        )
    }

    private func addTypedModel() {
        guard let normalized = CodexBarProvider.normalizedOpenRouterModelID(self.query) else {
            return
        }
        let matched = self.displayModels.first {
            $0.id.localizedCaseInsensitiveCompare(normalized) == .orderedSame ||
                $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        } ?? (self.filteredModels.count == 1 ? self.filteredModels.first : nil)
        let modelID = matched?.id ?? normalized
        self.selectedModelIDs.insert(modelID)
        self.selectedModelID = modelID
        self.query = ""
    }

    private func toggleModel(_ modelID: String) {
        if self.selectedModelIDs.contains(modelID) {
            self.removeModel(modelID)
        } else {
            self.selectedModelIDs.insert(modelID)
            if self.selectedModelID == nil {
                self.selectedModelID = modelID
            }
        }
    }

    private func removeModel(_ modelID: String) {
        self.selectedModelIDs.remove(modelID)
        if self.selectedModelID == modelID {
            self.selectedModelID = self.displayModels.first {
                $0.id != modelID && self.selectedModelIDs.contains($0.id)
            }?.id
        }
    }

    @MainActor
    private func refresh(_ action: @escaping () async throws -> Void) async {
        guard self.isRefreshing == false else { return }
        self.isRefreshing = true
        self.errorMessage = nil
        defer { self.isRefreshing = false }

        do {
            try await action()
        } catch {
            self.errorMessage = L.openRouterModelPickerRefreshFailure
        }
    }
}
