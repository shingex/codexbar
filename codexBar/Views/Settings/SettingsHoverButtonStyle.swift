import SwiftUI

struct SettingsHoverButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsHoverButtonBody(
            configuration: configuration,
            isDestructive: self.isDestructive
        )
    }
}

private struct SettingsHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isDestructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        self.configuration.label
            .foregroundColor(self.foregroundColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(self.isEnabled ? 1 : 0.45)
            .onHover { self.isHovering = $0 }
    }

    private var foregroundColor: Color {
        if self.isDestructive, self.isEnabled {
            return .red
        }
        return .primary
    }

    private var backgroundColor: Color {
        if self.isEnabled == false {
            return Color.clear
        }
        if self.configuration.isPressed {
            return self.isDestructive ? Color.red.opacity(0.16) : Color.accentColor.opacity(0.18)
        }
        if self.isHovering {
            return self.isDestructive ? Color.red.opacity(0.10) : Color.secondary.opacity(0.12)
        }
        return Color.clear
    }
}
