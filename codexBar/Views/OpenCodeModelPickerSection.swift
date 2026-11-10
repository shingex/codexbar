import SwiftUI

struct OpenCodeModelPickerSection: View {
    let plan: CodexBarOpenCodePlan
    @Binding var apiKey: String
    @Binding var selectedModelIDs: Set<String>
    @Binding var selectedModelID: String?
    @Binding var models: [OpenCodeModel]
    @Binding var fetchedAt: Date?
    let refreshAction: (CodexBarOpenCodePlan, String) async throws -> OpenCodeModelCatalogSnapshot

    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredModels: [OpenCodeModel] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.isEmpty == false else { return self.models }
        return self.models.filter {
            $0.id.lowercased().contains(query) ||
                $0.name.lowercased().contains(query) ||
                ($0.family?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L.openRouterModelPickerSearchPlaceholder, text: self.$searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                Button {
                    Task { await self.refresh() }
                } label: {
                    Image(systemName: self.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(self.isLoading || self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L.openRouterModelPickerRefresh)
            }

            HStack {
                TextField(L.thirdPartyModelIDPlaceholder, text: self.$customModelID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { self.addCustomModel() }
                Button(L.thirdPartyAddModelAction) { self.addCustomModel() }
                    .disabled(self.customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Picker(L.zh ? "请求模型" : "Request model", selection: self.$selectedModelID) {
                Text(L.zh ? "请选择" : "Choose a model").tag(String?.none)
                ForEach(Array(self.selectedModelIDs).sorted(), id: \.self) { id in
                    Text(id).tag(Optional(id))
                }
            }

            if let errorMessage = self.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.models.isEmpty {
                Text(self.isLoading ? L.openCodeModelsLoading : L.openCodeModelsEmpty)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(self.filteredModels) { model in
                            self.modelRow(model)
                            if model.id != self.filteredModels.last?.id {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)
                .layoutPriority(1)
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
    }

    private func addCustomModel() {
        guard let id = CodexBarProvider.normalizedOpenRouterModelID(self.customModelID) else { return }
        self.selectedModelIDs.insert(id)
        self.selectedModelID = id
        self.customModelID = ""
    }

    private func modelRow(_ model: OpenCodeModel) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: self.bindingForModel(model.id))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(model.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let context = model.contextLimit {
                Text(self.formatContext(context))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if self.selectedModelID == model.id {
                Text(L.thirdPartyCurrentModel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
            } else if self.selectedModelIDs.contains(model.id) {
                Button(L.thirdPartySetCurrentModel) {
                    self.selectedModelID = model.id
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if self.selectedModelIDs.contains(model.id) {
                self.selectedModelIDs.remove(model.id)
                if self.selectedModelID == model.id {
                    self.selectedModelID = self.orderedSelectedModelIDs.first
                }
            } else {
                self.selectedModelIDs.insert(model.id)
                self.selectedModelID = self.selectedModelID ?? model.id
            }
        }
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

    private var orderedSelectedModelIDs: [String] {
        let catalogIDs = self.models.map(\.id)
        let selected = self.selectedModelIDs
        return CodexBarProvider.normalizedOpenRouterModelIDs(catalogIDs.filter { selected.contains($0) } + selected.sorted())
    }

    @MainActor
    private func refresh() async {
        let trimmedAPIKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return }
        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }
        do {
            let snapshot = try await self.refreshAction(self.plan, trimmedAPIKey)
            self.models = snapshot.models
            self.fetchedAt = snapshot.fetchedAt

        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func formatContext(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)K"
        }
        return "\(value)"
    }
}
