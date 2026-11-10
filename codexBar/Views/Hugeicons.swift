import CoreText
import AppKit
import SwiftUI

enum Hugeicons: String {
    case addSquare = "\u{F1512}"
    case check = "\u{F3082}"
    case edit02 = "\u{F1C02}"
    case delete = "\u{F1B34}"
    case refresh = "\u{F244E}"
    case refresh04 = "\u{F244B}"
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

    /// Native Menu controls must not recolor this toolbar glyph as a template.
    func originalImage(size: CGFloat, color: NSColor) -> Image {
        _ = Self.registerFont
        let glyph = self.rawValue as NSString
        let font = NSFont(name: "hugeicons-stroke-rounded", size: size) ?? NSFont.systemFont(ofSize: size)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let glyphSize = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image).renderingMode(.original)
    }

    func makeMenuTemplateImage() -> NSImage {
        _ = Self.registerFont
        let pointSize = NSSize(width: 16, height: 16)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        let glyph = self.rawValue as NSString
        let font = NSFont(name: "hugeicons-stroke-rounded", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let glyphSize = glyph.size(withAttributes: attributes)
        glyph.draw(at: NSPoint(x: (16 - glyphSize.width) / 2, y: (16 - glyphSize.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    var menuImage: Image {
        Image(nsImage: self.makeMenuTemplateImage()).renderingMode(.template)
    }
}
