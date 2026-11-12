import SwiftUI

struct OpenCodeModelPickerSection: View {
    let plan: CodexBarOpenCodePlan
    @Binding var apiKey: String
    @Binding var selectedModelIDs: Set<String>
    @Binding var selectedModelID: String?
    @Binding var models: [OpenCodeModel]
    @Binding var fetchedAt: Date?
    let refreshAction: (CodexBarOpenCodePlan, String) async throws -> OpenCodeModelCatalogSnapshot
    var refreshEnabled: Bool? = nil

    private var pickerModels: [ProviderModelPickerItem] {
        self.models.map {
            ProviderModelPickerItem(
                id: $0.id,
                name: $0.name,
                context: $0.contextLimit.map(Self.formatContext)
            )
        }
    }

    var body: some View {
        ProviderModelPickerSection(
            selectedModelIDs: self.$selectedModelIDs,
            selectedModelID: self.$selectedModelID,
            models: self.pickerModels,
            emptyMessage: L.openCodeModelsEmpty,
            refreshEnabled: self.refreshEnabled
                ?? (self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
            refreshAction: {
                let snapshot = try await self.refreshAction(self.plan, self.apiKey)
                self.models = snapshot.models
                self.fetchedAt = snapshot.fetchedAt
            }
        )
    }

    private static func formatContext(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)K"
        }
        return "\(value)"
    }
}
