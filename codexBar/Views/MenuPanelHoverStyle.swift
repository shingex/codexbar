import SwiftUI

enum MenuPanelLayout {
    static let horizontalInset: CGFloat = 12
    static let blockContentHorizontalInset: CGFloat = 10
    static let blockVerticalInset: CGFloat = 8
    static let compactSectionTopInset: CGFloat = 4
    static let sectionActionButtonSize: CGFloat = 20
    static let sectionCountSlotWidth: CGFloat = 44
    static let primaryActionWidth: CGFloat = 54
}

struct MenuPanelCurrentIndicator: View {
    var width: CGFloat = MenuPanelLayout.primaryActionWidth

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.8)
            }
            .frame(width: self.width, alignment: .center)
    }
}

struct MenuPanelHoverChrome: ViewModifier {
    var cornerRadius: CGFloat = 6
    var active: Bool = false
    var hoverOpacity: Double = 0.12
    var pressedOpacity: Double = 0.18
    var activeOpacity: Double = 0.10

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(self.backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: self.cornerRadius))
            .opacity(self.isEnabled ? 1 : 0.48)
            .onHover { self.isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard self.isEnabled else { return Color.clear }
        if self.active {
            return Color.accentColor.opacity(self.isHovering ? self.pressedOpacity : self.activeOpacity)
        }
        if self.isHovering {
            return Color.secondary.opacity(self.hoverOpacity)
        }
        return Color.clear
    }
}

extension View {
    func menuPanelHoverChrome(
        cornerRadius: CGFloat = 6,
        active: Bool = false,
        hoverOpacity: Double = 0.12,
        pressedOpacity: Double = 0.18,
        activeOpacity: Double = 0.10
    ) -> some View {
        self.modifier(
            MenuPanelHoverChrome(
                cornerRadius: cornerRadius,
                active: active,
                hoverOpacity: hoverOpacity,
                pressedOpacity: pressedOpacity,
                activeOpacity: activeOpacity
            )
        )
    }
}
