#!/usr/bin/env swift

import AppKit

// Frames the Mac captures from capture-mac.sh for the Mac App Store, in the
// iOS screenshots' style: the same pink, the same rounded type, the window
// below its header and caption. Captures live in `Raw/Mac/<lang>/` and are
// written to `Mac/<lang>/`.

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let languages = ["en", "ja"]
let canvasSize = NSSize(width: 2880, height: 1800)

struct Copy {
    let header: String
    let caption: String
}

struct Screenshot {
    let name: String
    /// Keyed by language code. A language without copy is skipped.
    let copy: [String: Copy]
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

// The app icon's pink, as on iPhone and iPad.
let gradientTop = color(0xF2789A)
let gradientBottom = color(0xC2185B)

// Three shots between them cover what the six iOS ones do.
let screenshots = [
    Screenshot(
        name: "01-paint",
        copy: [
            "en": Copy(header: "Paint like you mean it", caption: "Layers, masks, and brushes that follow your pen's pressure"),
            "ja": Copy(header: "思いのままに描く", caption: "レイヤーもマスクも、ペンの筆圧に応えるブラシも"),
        ]
    ),
    Screenshot(
        name: "02-filters",
        copy: [
            "en": Copy(header: "Filters you can take back", caption: "Curves, levels, and blurs that stay editable, and a mosaic for what's private"),
            "ja": Copy(header: "あとから変えられるフィルタ", caption: "トーンカーブもレベルもぼかしも、隠したい所にはモザイクも"),
        ]
    ),
    Screenshot(
        name: "03-design",
        copy: [
            "en": Copy(header: "Text, shapes, and Photoshop files", caption: "Set words along a path, shape every point, and open PSDs"),
            "ja": Copy(header: "文字も図形もPhotoshopファイルも", caption: "パスに沿った文字、ポイントの編集、PSDもそのまま開ける"),
        ]
    ),
]

// MARK: - Text

/// SF Pro Rounded. It has no Japanese, so that falls back to Tsukushi A Round
/// Gothic, which unlike Hiragino Maru Gothic comes in a bold to match the header.
func roundedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    let japanese = weight >= .semibold ? "TsukuARdGothic-Bold" : "TsukuARdGothic-Regular"
    let rounded = (system.withDesign(.rounded) ?? system).addingAttributes([
        .cascadeList: [NSFontDescriptor(name: japanese, size: size)],
    ])
    return NSFont(descriptor: rounded, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

/// One line of text at the largest size up to `size` that fits `maxWidth`.
struct Line {
    let text: String
    let attributes: [NSAttributedString.Key: Any]
    let size: NSSize
    /// How far below the top of the line box the glyphs actually start and end.
    let inkTop: CGFloat
    let inkBottom: CGFloat

    init(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat) {
        var fontSize = size
        var attributes: [NSAttributedString.Key: Any] = [:]
        var lineSize = NSSize.zero
        while fontSize > 10 {
            attributes = [.font: roundedFont(ofSize: fontSize, weight: weight), .foregroundColor: color]
            lineSize = (text as NSString).size(withAttributes: attributes)
            if lineSize.width <= maxWidth { break }
            fontSize -= 2
        }
        self.text = text
        self.attributes = attributes
        self.size = lineSize
        (inkTop, inkBottom) = Line.inkInsets(of: text, attributes: attributes, size: lineSize)
    }

    /// Centering by font metrics leaves the text looking off, since the line box carries
    /// space above the capitals and below the baseline. So the line is rendered once and
    /// the rows its glyphs cover are measured.
    private static func inkInsets(
        of text: String, attributes: [NSAttributedString.Key: Any], size: NSSize
    ) -> (CGFloat, CGFloat) {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return (0, size.height) }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        var opaque = attributes
        opaque[.foregroundColor] = NSColor.black
        (text as NSString).draw(at: .zero, withAttributes: opaque)
        NSGraphicsContext.restoreGraphicsState()

        // Bitmap rows run top to bottom.
        let inked = (0..<height).filter { y in
            (0..<width).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        guard let first = inked.first, let last = inked.last else { return (0, size.height) }
        return (CGFloat(first), CGFloat(last + 1))
    }

    /// Draws the line centered across the canvas, with the top of its line box at `top`.
    func draw(top: CGFloat) {
        (text as NSString).draw(
            at: NSPoint(x: (canvasSize.width - size.width) / 2, y: top - size.height),
            withAttributes: attributes
        )
    }
}

// MARK: - Composition

func compose(_ shot: Screenshot, language: String) -> Bool {
    guard let copy = shot.copy[language] else { return true }
    let rawURL = scriptDir.appendingPathComponent("Raw/Mac/\(language)/\(shot.name).png")
    guard let raw = NSImage(contentsOf: rawURL),
          let rawPixels = raw.representations.first.map({ NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }) else {
        print("missing raw capture: \(rawURL.path)")
        return false
    }

    let image = NSImage(size: canvasSize)
    image.lockFocus()

    NSGradient(starting: gradientTop, ending: gradientBottom)?
        .draw(in: NSRect(origin: .zero, size: canvasSize), angle: -90)

    // The window fills what is left below a band that holds the text. AppKit's
    // origin is bottom-left.
    let textWidth = canvasSize.width - 240
    let header = Line(copy.header, size: 120, weight: .bold, color: .white, maxWidth: textWidth)
    let caption = Line(
        copy.caption, size: 60, weight: .medium,
        color: NSColor.white.withAlphaComponent(0.92), maxWidth: textWidth
    )
    let captionGap: CGFloat = 8
    // From the top of the header's ink to the bottom of the caption's.
    let inkHeight = header.size.height + captionGap + caption.inkBottom - header.inkTop
    let textPadding: CGFloat = 90
    let bottomMargin: CGFloat = 110
    let windowTop = canvasSize.height - inkHeight - 2 * textPadding
    let windowHeight = windowTop - bottomMargin
    let windowSize = NSSize(width: windowHeight * rawPixels.width / rawPixels.height, height: windowHeight)
    let windowRect = NSRect(
        x: ((canvasSize.width - windowSize.width) / 2).rounded(), y: bottomMargin,
        width: windowSize.width, height: windowSize.height
    )

    // The text's ink is centered in the band between the top of the canvas and the window.
    let inkTop = (canvasSize.height + windowTop + inkHeight) / 2
    let headerTop = (inkTop + header.inkTop).rounded()
    header.draw(top: headerTop)
    caption.draw(top: headerTop - header.size.height - captionGap)

    // The capture keeps the window's rounded corners; the shadow is drawn
    // here, as macOS draws one under a window.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 70
    shadow.shadowOffset = NSSize(width: 0, height: -30)
    shadow.set()
    raw.draw(in: windowRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()

    // Rasterize at exactly the canvas size in pixels.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return false }
    bitmap.size = canvasSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: canvasSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    let outDir = scriptDir.appendingPathComponent("Mac/\(language)")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("\(shot.name).png")
    do {
        try png.write(to: outURL)
        print("wrote Mac/\(language)/\(shot.name).png")
        return true
    } catch {
        print("failed to write \(outURL.path): \(error)")
        return false
    }
}

var allOK = true
for language in languages {
    for shot in screenshots {
        allOK = compose(shot, language: language) && allOK
    }
}
exit(allOK ? 0 : 1)
