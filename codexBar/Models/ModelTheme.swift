import SwiftUI

/// Monochrome brands follow the system accent; multicolour and unknown marks use blue.
enum ModelTheme {
    static func color(config: CodexBarConfig) -> Color {
        if config.activeProvider()?.kind == .openAIOAuth { return .primary }
        guard let provider = config.activeProvider(), let identity = ModelDisplayIdentityResolver.identity(for: provider) else { return .blue }
        switch identity.providerCode {
        case "DS": return Color(red: 0.30, green: 0.42, blue: 0.96)
        case "CL": return Color(red: 0.80, green: 0.48, blue: 0.35)
        case "MM": return .blue
        case "QW": return .purple
        case "KM", "GX", "ZA": return .primary
        default: return .blue
        }
    }
}
