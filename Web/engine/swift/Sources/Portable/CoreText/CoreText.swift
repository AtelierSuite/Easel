@_exported import AppKit

// Core Text's layout objects over TextSystem's layout. A "glyph" here is a
// number standing for one character (grapheme), since the browser shapes
// text itself and doesn't hand out glyph numbers.

public typealias CTFont = NSFont
public let kCTFontAttributeName: CFString = NSAttributedString.Key.font.rawValue

enum Glyphs {
    nonisolated(unsafe) static var strings: [String] = [""]
    nonisolated(unsafe) static var numbers: [String: CGGlyph] = [:]

    static func glyph(for string: String) -> CGGlyph {
        if let number = numbers[string] { return number }
        guard strings.count < Int(UInt16.max) else { return 0 }
        let number = CGGlyph(strings.count)
        strings.append(string)
        numbers[string] = number
        return number
    }

    static func string(for glyph: CGGlyph) -> String { Int(glyph) < strings.count ? strings[Int(glyph)] : "" }
}

public final class CTRun {
    let attributes: [NSAttributedString.Key: Any]
    let range: CFRange
    let position: CGPoint
    let glyphs: [CGGlyph]
    let advances: [CGSize]

    init(attributes: [NSAttributedString.Key: Any], range: CFRange, position: CGPoint, glyphs: [CGGlyph], advances: [CGSize]) {
        self.attributes = attributes
        self.range = range
        self.position = position
        self.glyphs = glyphs
        self.advances = advances
    }
}

public final class CTLine {
    let runs: [CTRun]
    let width: Double
    init(runs: [CTRun], width: Double) {
        self.runs = runs
        self.width = width
    }
}

public final class CTFramesetter {
    let string: NSAttributedString
    init(string: NSAttributedString) { self.string = string }
}

public final class CTFrame {
    let lines: [CTLine]
    let origins: [CGPoint]
    init(lines: [CTLine], origins: [CGPoint]) {
        self.lines = lines
        self.origins = origins
    }
}

/// Lines of Core Text runs from TextSystem's layout. Origins are y up from
/// the bottom of a box `height` tall.
private func lines(of string: NSAttributedString, width: Double?, boxHeight: Double?) -> (lines: [CTLine], origins: [CGPoint]) {
    let layout = TextSystem.layout(string, width: width)
    let whole = string.string as NSString
    let height = boxHeight ?? layout.height
    var lines: [CTLine] = []
    var origins: [CGPoint] = []
    for line in layout.lines {
        var runs: [CTRun] = []
        for piece in line.pieces where piece.length > 0 {
            let range = NSRange(location: piece.start, length: piece.length)
            guard NSMaxRange(range) <= whole.length else { continue }
            let attributes = string.attributes(at: piece.start, effectiveRange: nil)
            let text = whole.substring(with: range)
            let characters = text.map(String.init)
            let each = characters.isEmpty ? 0 : piece.width / Double(characters.count)
            runs.append(CTRun(
                attributes: attributes, range: CFRange(location: piece.start, length: piece.length),
                position: CGPoint(x: piece.x - line.x, y: 0),
                glyphs: characters.map(Glyphs.glyph(for:)),
                advances: characters.map { _ in CGSize(width: each, height: 0) }
            ))
        }
        lines.append(CTLine(runs: runs, width: line.width))
        origins.append(CGPoint(x: line.x, y: height - line.baseline))
    }
    return (lines, origins)
}

public func CTFramesetterCreateWithAttributedString(_ string: NSAttributedString) -> CTFramesetter {
    CTFramesetter(string: string)
}

public func CTFramesetterCreateFrame(_ framesetter: CTFramesetter, _ range: CFRange, _ path: CGPath, _ attributes: CFDictionary?) -> CTFrame {
    let box = path.boundingBox
    let (lines, origins) = lines(of: framesetter.string, width: Double(box.width), boxHeight: Double(box.height))
    return CTFrame(lines: lines, origins: origins)
}

public func CTFrameGetLines(_ frame: CTFrame) -> CFArray { frame.lines }

public func CTFrameGetLineOrigins(_ frame: CTFrame, _ range: CFRange, _ origins: UnsafeMutablePointer<CGPoint>) {
    let start = range.location, count = range.length == 0 ? frame.origins.count - start : range.length
    for i in 0..<max(count, 0) where start + i < frame.origins.count { origins[i] = frame.origins[start + i] }
}

public func CTLineCreateWithAttributedString(_ string: NSAttributedString) -> CTLine {
    let (lines, _) = lines(of: string, width: nil, boxHeight: nil)
    return CTLine(runs: lines.flatMap(\.runs), width: lines.map(\.width).max() ?? 0)
}

public func CTLineGetGlyphRuns(_ line: CTLine) -> CFArray { line.runs }

public func CTLineGetTypographicBounds(
    _ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?, _ leading: UnsafeMutablePointer<CGFloat>?
) -> Double {
    let size = line.runs.compactMap { ($0.attributes[.font] as? NSFont)?.pointSize }.max() ?? 12
    ascent?.pointee = size * 0.8
    descent?.pointee = size * 0.2
    leading?.pointee = 0
    return line.width
}

public func CTRunGetStringRange(_ run: CTRun) -> CFRange { run.range }
public func CTRunGetGlyphCount(_ run: CTRun) -> CFIndex { run.glyphs.count }
public func CTRunGetAttributes(_ run: CTRun) -> CFDictionary {
    var result: [String: Any] = [:]
    for (key, value) in run.attributes { result[key.rawValue] = value }
    return result
}

public func CTRunGetPositions(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGPoint>) {
    var x = run.position.x
    let count = range.length == 0 ? run.glyphs.count - range.location : range.length
    for i in 0..<run.glyphs.count {
        if i >= range.location, i - range.location < count { buffer[i - range.location] = CGPoint(x: x, y: run.position.y) }
        x += run.advances[i].width
    }
}

public func CTRunGetGlyphs(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGGlyph>) {
    let count = range.length == 0 ? run.glyphs.count - range.location : range.length
    for i in 0..<count where range.location + i < run.glyphs.count { buffer[i] = run.glyphs[range.location + i] }
}

public func CTRunGetAdvances(_ run: CTRun, _ range: CFRange, _ buffer: UnsafeMutablePointer<CGSize>) {
    let count = range.length == 0 ? run.advances.count - range.location : range.length
    for i in 0..<count where range.location + i < run.advances.count { buffer[i] = run.advances[range.location + i] }
}

/// Draws glyphs with their baselines at `positions`, y up, in the fill colour.
public func CTFontDrawGlyphs(_ font: CTFont, _ glyphs: UnsafePointer<CGGlyph>, _ positions: UnsafePointer<CGPoint>, _ count: Int, _ context: CGContext) {
    let color = context.fillColor
    for i in 0..<count {
        let text = Glyphs.string(for: glyphs[i])
        guard !text.isEmpty else { continue }
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(color.w)),
        ])
        let layout = TextSystem.layout(string, width: nil)
        guard let line = layout.lines.first, layout.width > 0 else { continue }
        let ctm = context.ctm
        let scale = max(sqrt(abs(Double(ctm.a * ctm.d - ctm.b * ctm.c))), 0.01)
        guard let image = TextSystem.render(string, width: layout.width, height: layout.height, scale: scale) else { continue }
        // The picture's top is `baseline` above the glyph's baseline.
        let p = positions[i]
        context.draw(image, in: CGRect(x: p.x - CGFloat(line.x), y: p.y - CGFloat(layout.height - line.baseline), width: CGFloat(layout.width), height: CGFloat(layout.height)))
    }
}
