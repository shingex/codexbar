import CoreText
import AppKit
import SwiftUI

enum Hugeicons: String {
    case addSquare = "\u{F1512}"
    case check = "\u{F3082}"
    case edit02 = "\u{F1C02}"
    case delete = "\u{F1B34}"
    case refresh = "\u{F244E}"
    case settings = "\u{F257F}"
    case power = "\u{F238B}"
    case languages = "\u{F31E7}"
    case cancel = "\u{F18BC}"
    case warning = "\u{F33DC}"
    case upload = "\u{F28FB}"
    case downloadCircle = "\u{F1BBA}"

    private static let registerFont: Void = {
        if let url = Bundle.main.url(forResource: "hgi-stroke-rounded", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    func image(size: CGFloat) -> some View {
        _ = Self.registerFont
        return Text(self.rawValue)
            .font(.custom("hugeicons-stroke-rounded", size: size))
    }

    var menuImage: Image {
        _ = Self.registerFont
        let glyph = self.rawValue as NSString
        let font = NSFont(name: "hugeicons-stroke-rounded", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        icon.isTemplate = true
        return Image(nsImage: icon)
    }
}
