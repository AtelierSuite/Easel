import UIKit

/// Sets a text layer's words into pixels.
enum TextRenderer {
    static func font(for text: TextContent) -> UIFont {
        let size = max(1, text.fontSize)
        if let family = text.fontName, let font = font(family: family, text: text, size: size) { return font }
        var descriptor = UIFont.systemFont(ofSize: size, weight: text.isBold ? .bold : .regular).fontDescriptor
        let design: UIFontDescriptor.SystemDesign = switch text.design {
        case .standard: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
        descriptor = descriptor.withDesign(design) ?? descriptor
        if text.isItalic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// A face of a named family, bold and italic as asked where the family
    /// has them. Nil when no such family is installed.
    private static func font(family: String, text: TextContent, size: Double) -> UIFont? {
        guard !UIFont.fontNames(forFamilyName: family).isEmpty else { return nil }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        var traits: UIFontDescriptor.SymbolicTraits = []
        if text.isBold { traits.insert(.traitBold) }
        if text.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func attributedString(for text: TextContent) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch text.alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
        let color = UIColor(
            red: text.color.red, green: text.color.green, blue: text.color.blue, alpha: text.color.alpha
        )
        if let lineSpacing = text.lineSpacing { paragraph.lineHeightMultiple = max(lineSpacing, 0.1) }
        // An empty layer still needs a line's height to be found and tapped.
        let string = text.string.isEmpty ? " " : text.string
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: text), .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if let tracking = text.tracking { attributes[.tracking] = tracking * text.fontSize }
        // A kern of zero turns the font's pair kerning off.
        if text.usesKerning == false { attributes[.kern] = 0 }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// The text drawn on a transparent image just large enough to hold it,
    /// its outline and its background, with a little room so italics and
    /// descenders are not clipped.
    static func render(_ text: TextContent) -> CGImage {
        let string = attributedString(for: text)
        let bounds = string.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        let outlineWidth = text.outline.map { max(0.5, $0.width * text.fontSize) } ?? 0
        let backgroundPadding = text.background.map { $0.padding * text.fontSize } ?? 0
        // The box fills the image, so the slack for italics is inside it.
        let padding = ceil((text.background == nil ? text.fontSize * 0.15 : 0) + outlineWidth + backgroundPadding)
        let size = CGSize(
            width: min(ceil(bounds.width) + padding * 2, CGFloat(Bitmap.maximumDimension)),
            height: min(ceil(bounds.height) + padding * 2, CGFloat(Bitmap.maximumDimension))
        )
        let textRect = CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        return Bitmap.render(size: size) { context in
            UIGraphicsPushContext(context)
            if let background = text.background {
                let box = CGRect(origin: .zero, size: size)
                let radius = min(box.width, box.height) / 2 * min(max(background.cornerRadius, 0), 1)
                context.setFillColor(background.color.cgColor)
                context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            if let outline = text.outline {
                // Stroked first and filled over, so the outline sits wholly
                // outside the letters. A stroke width is a percentage of the
                // font size and straddles the edge, hence the doubling.
                let stroked = NSMutableAttributedString(attributedString: string)
                stroked.addAttributes([
                    .strokeColor: UIColor(cgColor: outline.color.cgColor),
                    .strokeWidth: outlineWidth * 2 / max(text.fontSize, 1) * 100,
                ], range: NSRange(location: 0, length: stroked.length))
                context.setLineJoin(.round)
                stroked.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            string.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            UIGraphicsPopContext()
        }
    }
}
