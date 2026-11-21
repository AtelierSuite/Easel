@_exported import CoreGraphics
import EaselHost

// Setting type on the web. The browser has the fonts and the shaping, so the
// page lays out and draws text when the engine asks (Web/engine/text.js),
// synchronously from the worker the engine runs in. Without a page (in the
// smoke tests), text is measured roughly and not drawn.

public struct TextFragment: Codable, Sendable {
    public var text: String
    public var family: String?
    public var design: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var color: [Double]
    public var tracking: Double
    public var underline: Bool
    public var baseline: Double
    public var strokeColor: [Double]?
    public var strokeWidth: Double?
}

public struct TextLayout: Codable, Sendable {
    public struct Piece: Codable, Sendable {
        /// Which fragment, and where in the whole string (UTF-16) it starts.
        public var fragment: Int
        public var start: Int
        public var length: Int
        public var x: Double
        public var width: Double
    }

    public struct Line: Codable, Sendable {
        public var x: Double
        /// The baseline, down from the top of the text.
        public var baseline: Double
        public var ascent: Double
        public var descent: Double
        public var width: Double
        public var pieces: [Piece]
    }

    public var width: Double
    public var height: Double
    public var lines: [Line]
}

private struct TextRequest: Encodable {
    var op: String
    var fragments: [TextFragment]
    var width: Double?
    var align: String
    var lineHeight: Double
    var scale: Double
    var pixelWidth: Int
    var pixelHeight: Int
}

public enum TextSystem {
    private static func ask(_ request: TextRequest) -> [UInt8]? {
        guard let json = try? JSONEncoder().encode(request) else { return nil }
        let length = json.withUnsafeBytes { easel_host_text($0.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32($0.count)) }
        guard length >= 0 else { return nil }
        var result = [UInt8](repeating: 0, count: Int(length))
        result.withUnsafeMutableBufferPointer { easel_host_result($0.baseAddress!) }
        return result
    }

    public static func fragments(of string: NSAttributedString) -> [TextFragment] {
        var result: [TextFragment] = []
        let whole = string.string as NSString
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length), options: []) { attributes, range, _ in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
            let color = (attributes[.foregroundColor] as? NSColor)?.components ?? [0, 0, 0, 1]
            let stroke = attributes[.strokeWidth] as? Double ?? (attributes[.strokeWidth] as? CGFloat).map(Double.init)
            result.append(TextFragment(
                text: whole.substring(with: range),
                family: font.isSystem ? nil : font.family,
                design: font.design,
                size: Double(font.pointSize),
                bold: font.isBold,
                italic: font.isItalic,
                color: color,
                tracking: number(attributes[.tracking]) + number(attributes[.kern]),
                underline: number(attributes[.underlineStyle]) != 0,
                baseline: number(attributes[.baselineOffset]),
                strokeColor: stroke.flatMap { $0 != 0 ? ((attributes[.strokeColor] as? NSColor)?.components ?? color) : nil },
                strokeWidth: stroke.flatMap { $0 != 0 ? $0 : nil }
            ))
        }
        return result
    }

    private static func number(_ value: Any?) -> Double {
        if let v = value as? Double { return v }
        if let v = value as? CGFloat { return Double(v) }
        if let v = value as? Int { return Double(v) }
        if let v = value as? Float { return Double(v) }
        return 0
    }

    private static func paragraph(of string: NSAttributedString) -> (align: String, lineHeight: Double) {
        guard string.length > 0, let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            return ("left", 1)
        }
        let align: String = switch style.alignment {
        case .center: "center"
        case .right: "right"
        case .justified: "justify"
        default: "left"
        }
        return (align, Double(style.lineHeightMultiple == 0 ? 1 : style.lineHeightMultiple))
    }

    /// Lines and where each piece of them goes, for text up to `width` wide.
    public static func layout(_ string: NSAttributedString, width: Double?) -> TextLayout {
        let fragments = fragments(of: string)
        let (align, lineHeight) = paragraph(of: string)
        let request = TextRequest(op: "layout", fragments: fragments, width: width, align: align, lineHeight: lineHeight, scale: 1, pixelWidth: 0, pixelHeight: 0)
        if let bytes = ask(request), let layout = try? JSONDecoder().decode(TextLayout.self, from: Data(bytes)) { return layout }
        return estimate(fragments, lineHeight: lineHeight)
    }

    /// The text drawn into a transparent picture `width` by `height` points at `scale` pixels a point.
    public static func render(_ string: NSAttributedString, width: Double, height: Double, scale: Double) -> CGImage? {
        let fragments = fragments(of: string)
        let (align, lineHeight) = paragraph(of: string)
        let pixelWidth = max(Int((width * scale).rounded(.up)), 1), pixelHeight = max(Int((height * scale).rounded(.up)), 1)
        guard pixelWidth * pixelHeight <= 64_000_000 else { return nil }
        let request = TextRequest(op: "draw", fragments: fragments, width: width, align: align, lineHeight: lineHeight, scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard let bytes = ask(request), bytes.count == pixelWidth * pixelHeight * 4 else { return nil }
        // The canvas gives straight alpha.
        var rgba = bytes
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] < 255 {
            let a = Int(rgba[i + 3])
            rgba[i] = UInt8((Int(rgba[i]) * a + 127) / 255)
            rgba[i + 1] = UInt8((Int(rgba[i + 1]) * a + 127) / 255)
            rgba[i + 2] = UInt8((Int(rgba[i + 2]) * a + 127) / 255)
        }
        return CGImage.fromRGBA(rgba, width: pixelWidth, height: pixelHeight)
    }

    private static func estimate(_ fragments: [TextFragment], lineHeight: Double) -> TextLayout {
        var lines: [TextLayout.Line] = []
        var y = 0.0
        var offset = 0
        var current = TextLayout.Line(x: 0, baseline: 0, ascent: 0, descent: 0, width: 0, pieces: [])
        func finish(_ size: Double) {
            let ascent = max(current.ascent, size * 0.8), descent = max(current.descent, size * 0.2)
            current.ascent = ascent
            current.descent = descent
            current.baseline = y + ascent
            y += (ascent + descent) * lineHeight
            lines.append(current)
            current = TextLayout.Line(x: 0, baseline: 0, ascent: 0, descent: 0, width: 0, pieces: [])
        }
        var lastSize = 12.0
        for (index, fragment) in fragments.enumerated() {
            lastSize = fragment.size
            let parts = fragment.text.components(separatedBy: "\n")
            for (p, part) in parts.enumerated() {
                let width = Double(part.utf16.count) * fragment.size * 0.55
                current.pieces.append(TextLayout.Piece(fragment: index, start: offset, length: part.utf16.count, x: current.width, width: width))
                current.width += width
                current.ascent = max(current.ascent, fragment.size * 0.8)
                current.descent = max(current.descent, fragment.size * 0.2)
                offset += part.utf16.count
                if p < parts.count - 1 {
                    finish(fragment.size)
                    offset += 1
                }
            }
        }
        finish(lastSize)
        return TextLayout(width: lines.map(\.width).max() ?? 0, height: y, lines: lines)
    }
}

extension CGImage {
    public static func fromRGBA(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba)) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
