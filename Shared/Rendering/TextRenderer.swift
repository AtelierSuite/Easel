import CoreText
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
        let attributed = NSMutableAttributedString(string: string, attributes: attributes)
        for run in text.runs ?? [] where NSMaxRange(run.range) <= attributed.length {
            attributed.addAttributes(self.attributes(of: run.style, over: text), range: run.range)
        }
        return attributed
    }

    /// What a run's style changes from the layer's own.
    private static func attributes(of style: TextRun.Style, over text: TextContent) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if style.sizeScale != nil || style.isBold != nil || style.isItalic != nil {
            var face = text
            face.fontSize = text.fontSize * (style.sizeScale ?? 1)
            face.isBold = style.isBold ?? text.isBold
            face.isItalic = style.isItalic ?? text.isItalic
            attributes[.font] = font(for: face)
        }
        if let color = style.color {
            attributes[.foregroundColor] = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        }
        if style.isUnderlined == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        // Core Text drops a kern where there is tracking, so a run's
        // kerning goes on top of the layer's tracking instead.
        if let kerning = style.kerning { attributes[.tracking] = ((text.tracking ?? 0) + kerning) * text.fontSize }
        if let shift = style.baselineShift { attributes[.baselineOffset] = shift * text.fontSize }
        return attributes
    }

    /// The text drawn on a transparent image just large enough to hold it,
    /// its outline and its background, with a little room so italics and
    /// descenders are not clipped.
    static func render(_ text: TextContent) -> CGImage {
        let size = imageSize(for: text)
        return Bitmap.render(size: size) { draw(text, in: $0, size: size) }
    }

    /// The size of the image `render` draws, room round the words and all.
    static func imageSize(for text: TextContent) -> CGSize {
        layout(for: text).size
    }

    private static func layout(for text: TextContent) -> (string: NSAttributedString, size: CGSize, padding: CGFloat, outlineWidth: Double) {
        let string = attributedString(for: text)
        let boxWidth = text.boxWidth.map { max($0, 1) }
        var bounds = string.boundingRect(
            with: CGSize(width: boxWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        // A paragraph keeps its box's width, so its lines line up in it.
        if let boxWidth { bounds.size.width = boxWidth }
        let outlineWidth = text.outline.map { max(0.5, $0.width * text.fontSize) } ?? 0
        let backgroundPadding = text.background.map { $0.padding * text.fontSize } ?? 0
        // The box fills the image, so the slack for italics is inside it.
        let padding = ceil((text.background == nil ? text.fontSize * 0.15 : 0) + outlineWidth + backgroundPadding)
        let size = CGSize(
            width: min(ceil(bounds.width) + padding * 2, CGFloat(Bitmap.maximumDimension)),
            height: min(ceil(bounds.height) + padding * 2, CGFloat(Bitmap.maximumDimension))
        )
        return (string, size, padding, outlineWidth)
    }

    /// A stretch of text set in one style on one line, where it sits in the
    /// image `render` draws: what a vector file writes as words.
    struct SetRun {
        var string: String
        /// Where its baseline starts, y running down.
        var origin: CGPoint
        var font: UIFont
        var color: UIColor
        /// Extra room after each letter, in pixels.
        var spacing: Double
        var isUnderlined: Bool
    }

    /// The text laid out line by line and style by style as `render` sets
    /// it, with the image's size and the outline's width.
    static func setRuns(for text: TextContent) -> (runs: [SetRun], size: CGSize, outlineWidth: Double) {
        let (string, size, padding, outlineWidth) = layout(for: text)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        // Core Text counts y up; a little room below so no line is dropped.
        let box = CGRect(x: padding, y: padding - 2, width: size.width - padding * 2, height: size.height - padding * 2 + 2)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let nsString = string.string as NSString
        var runs: [SetRun] = []
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let range = CTRunGetStringRange(run)
                guard range.length > 0 else { continue }
                let piece = nsString.substring(with: NSRange(location: range.location, length: range.length))
                guard !piece.trimmingCharacters(in: .newlines).isEmpty else { continue }
                var start = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &start)
                let attributes = string.attributes(at: range.location, effectiveRange: nil)
                let font = attributes[.font] as? UIFont ?? font(for: text)
                let spacing = (attributes[.tracking] as? Double ?? 0) + (attributes[.kern] as? Double ?? 0)
                let shift = attributes[.baselineOffset] as? Double ?? 0
                runs.append(SetRun(
                    string: piece.trimmingCharacters(in: .newlines),
                    origin: CGPoint(x: box.minX + origin.x + start.x, y: size.height - (box.minY + origin.y) - shift),
                    font: font, color: attributes[.foregroundColor] as? UIColor ?? .black, spacing: spacing,
                    isUnderlined: (attributes[.underlineStyle] as? Int ?? 0) != 0
                ))
            }
        }
        return (runs, size, outlineWidth)
    }

    /// Draws the text, its outline and background into `context`, which is
    /// set up with y running down over a rectangle of `size` — the image's,
    /// or a page's when the words go into a PDF as words.
    static func draw(_ text: TextContent, in context: CGContext, size: CGSize) {
        let (string, _, padding, outlineWidth) = layout(for: text)
        let textRect = CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
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
