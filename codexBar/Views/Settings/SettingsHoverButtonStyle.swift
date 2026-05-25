import SwiftUI

struct SettingsHoverButtonStyle: ButtonStyle {
    var isDestructive = false
    var isPrimary = false
    var horizontalPadding: CGFloat = 9
    var verticalPadding: CGFloat = 4
    var minWidth: CGFloat?
    var minHeight: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        SettingsHoverButtonBody(
            configuration: configuration,
            isDestructive: self.isDestructive,
            isPrimary: self.isPrimary,
            horizontalPadding: self.horizontalPadding,
            verticalPadding: self.verticalPadding,
            minWidth: self.minWidth,
            minHeight: self.minHeight
        )
    }
}

private struct SettingsHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isDestructive: Bool
    let isPrimary: Bool
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        self.configuration.label
            .foregroundColor(self.foregroundColor)
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, self.verticalPadding)
            .frame(minWidth: self.minWidth, minHeight: self.minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(self.borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { self.isHovering = $0 }
    }

    private var foregroundColor: Color {
        if self.isEnabled == false {
            return .secondary
        }
        if self.isPrimary {
            return .white
        }
        if self.isDestructive, self.isEnabled {
            return .red
        }
        return .primary
    }

    private var backgroundColor: Color {
        if self.isEnabled == false {
            return Color.secondary.opacity(0.08)
        }
        if self.isPrimary {
            if self.configuration.isPressed {
                return Color.accentColor.opacity(0.78)
            }
            if self.isHovering {
                return Color.accentColor.opacity(0.88)
            }
            return Color.accentColor
        }
        if self.configuration.isPressed {
            return self.isDestructive ? Color.red.opacity(0.16) : Color.accentColor.opacity(0.18)
        }
        if self.isHovering {
            return self.isDestructive ? Color.red.opacity(0.10) : Color.secondary.opacity(0.12)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if self.isEnabled == false {
            return Color.primary.opacity(0.08)
        }
        if self.isPrimary {
            return Color.white.opacity(self.isHovering || self.configuration.isPressed ? 0.30 : 0)
        }
        if self.configuration.isPressed || self.isHovering {
            return self.isDestructive ? Color.red.opacity(0.16) : Color.primary.opacity(0.10)
        }
        return Color.clear
    }
}
