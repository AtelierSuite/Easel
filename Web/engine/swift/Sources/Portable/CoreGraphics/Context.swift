import Foundation

public enum CGBlendMode: Int32, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference,
         exclusion, hue, saturation, color, luminosity, clear, copy, sourceIn, sourceOut, sourceAtop, destinationOver,
         destinationIn, destinationOut, destinationAtop, xor, plusDarker, plusLighter
}

public enum CGPathDrawingMode: Int32, Sendable {
    case fill, eoFill, stroke, fillStroke, eoFillStroke
}

public enum CGTextDrawingMode: Int32, Sendable {
    case fill, stroke, fillStroke, invisible, fillClip, strokeClip, fillStrokeClip, clip
}

public struct CGGradientDrawingOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let drawsBeforeStartLocation = CGGradientDrawingOptions(rawValue: 1)
    public static let drawsAfterEndLocation = CGGradientDrawingOptions(rawValue: 2)
}

public final class CGGradient: @unchecked Sendable {
    /// Premultiplied colours sampled evenly from start to end.
    let table: [SIMD4<Float>]

    public init?(colorsSpace space: CGColorSpace?, colors: CFArray, locations: UnsafePointer<CGFloat>?) {
        let colors = colors.compactMap { $0 as? CGColor }
        guard !colors.isEmpty else { return nil }
        let stops = (0..<colors.count).map { i -> (CGFloat, SIMD4<Float>) in
            let c = colors[i].rgba
            let location = locations?[i] ?? (colors.count == 1 ? 0 : CGFloat(i) / CGFloat(colors.count - 1))
            return (location, SIMD4(Float(c.0), Float(c.1), Float(c.2), Float(c.3)))
        }
        table = Self.table(stops)
    }

    public init?(colorSpace space: CGColorSpace, colorComponents: UnsafePointer<CGFloat>, locations: UnsafePointer<CGFloat>?, count: Int) {
        guard count > 0 else { return nil }
        let n = space.numberOfComponents + 1
        let stops = (0..<count).map { i -> (CGFloat, SIMD4<Float>) in
            let location = locations?[i] ?? (count == 1 ? 0 : CGFloat(i) / CGFloat(count - 1))
            let c = (0..<n).map { colorComponents[i * n + $0] }
            let color = n == 2 ? SIMD4(Float(c[0]), Float(c[0]), Float(c[0]), Float(c[1])) : SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
            return (location, color)
        }
        table = Self.table(stops)
    }

    private static func table(_ stops: [(CGFloat, SIMD4<Float>)]) -> [SIMD4<Float>] {
        let sorted = stops.sorted { $0.0 < $1.0 }
        return (0..<1024).map { i in
            let t = CGFloat(i) / 1023
            var color = sorted[0].1
            if t >= sorted[sorted.count - 1].0 {
                color = sorted[sorted.count - 1].1
            } else if t > sorted[0].0 {
                for k in 1..<sorted.count where t <= sorted[k].0 {
                    let a = sorted[k - 1], b = sorted[k]
                    let f = Float(b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 1)
                    color = a.1 + (b.1 - a.1) * f
                    break
                }
            }
            return SIMD4(color.x * color.w, color.y * color.w, color.z * color.w, color.w)
        }
    }

    @inline(__always) func color(at t: Double) -> SIMD4<Float> {
        table[Int((min(max(t, 0), 1) * 1023).rounded())]
    }
}

/// Where a drawing's colour comes from, pixel by pixel in raster space.
enum Paint {
    case solid(SIMD4<Float>)
    case image(ImagePaint)
    case gradient((Int, Int) -> SIMD4<Float>?)
    case surface(Surface, dx: Int, dy: Int)

    @inline(__always) func color(_ x: Int, _ y: Int) -> SIMD4<Float>? {
        switch self {
        case .solid(let c): return c
        case .image(let paint): return paint.sample(x, y)
        case .gradient(let f): return f(x, y)
        case .surface(let s, let dx, let dy):
            let sx = x - dx, sy = y - dy
            guard sx >= 0, sy >= 0, sx < s.width, sy < s.height else { return .zero }
            return s.read(sx, sy)
        }
    }

    func moved(dx: Int, dy: Int) -> Paint {
        if dx == 0, dy == 0 { return self }
        return .gradient { x, y in self.color(x - dx, y - dy) }
    }
}

struct ImagePaint {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// Raster space to image pixel space.
    let inverse: CGAffineTransform
    let smooth: Bool
    let tiled: Bool
    let integerOffset: (Int, Int)?

    init(image: CGImage, toRaster: CGAffineTransform, quality: CGInterpolationQuality, tiled: Bool = false) {
        // How many raster pixels one image pixel covers.
        let scale = sqrt(abs(toRaster.a * toRaster.d - toRaster.b * toRaster.c))
        var level = 0
        if quality != .none, scale > 0, scale < 0.5, !tiled { level = min(Int(log2(1 / Double(scale))), 12) }
        let mip = image.mipmap(level: level)
        pixels = mip.pixels
        width = mip.width
        height = mip.height
        let fromLevel = CGAffineTransform(scaleX: CGFloat(image.width) / CGFloat(mip.width), y: CGFloat(image.height) / CGFloat(mip.height))
        let t = fromLevel.concatenating(toRaster)
        inverse = t.inverted()
        smooth = quality != .none && image.shouldInterpolate
        self.tiled = tiled
        if abs(t.a - 1) < 1e-9, abs(t.d - 1) < 1e-9, t.b == 0, t.c == 0, abs(t.tx - t.tx.rounded()) < 1e-6, abs(t.ty - t.ty.rounded()) < 1e-6 {
            integerOffset = (Int(t.tx.rounded()), Int(t.ty.rounded()))
        } else {
            integerOffset = nil
        }
    }

    @inline(__always) private func fetch(_ x: Int, _ y: Int) -> SIMD4<Float> {
        var x = x, y = y
        if tiled {
            x %= width; if x < 0 { x += width }
            y %= height; if y < 0 { y += height }
        } else {
            x = min(max(x, 0), width - 1)
            y = min(max(y, 0), height - 1)
        }
        let i = (y * width + x) * 4
        return SIMD4(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3])) * (1 / 255)
    }

    @inline(__always) func sample(_ x: Int, _ y: Int) -> SIMD4<Float> {
        if let (ox, oy) = integerOffset {
            let sx = x - ox, sy = y - oy
            if tiled || (sx >= 0 && sy >= 0 && sx < width && sy < height) { return fetch(sx, sy) }
            return fetch(min(max(sx, 0), width - 1), min(max(sy, 0), height - 1))
        }
        let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
        if !smooth { return fetch(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))) }
        let fx = Double(p.x) - 0.5, fy = Double(p.y) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let top = fetch(x0, y0) * (1 - tx) + fetch(x0 + 1, y0) * tx
        let bottom = fetch(x0, y0 + 1) * (1 - tx) + fetch(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }
}

private struct GState {
    var ctm = CGAffineTransform.identity
    var clip: Clip?
    var fill = SIMD4<Float>(0, 0, 0, 1)
    var stroke = SIMD4<Float>(0, 0, 0, 1)
    var lineWidth: CGFloat = 1
    var lineCap = CGLineCap.butt
    var lineJoin = CGLineJoin.miter
    var miterLimit: CGFloat = 10
    var dashPhase: CGFloat = 0
    var dashLengths: [CGFloat] = []
    var alpha: CGFloat = 1
    var blendMode = CGBlendMode.normal
    var interpolation = CGInterpolationQuality.default
    var antialias = true
    var shadow: (offset: CGSize, blur: CGFloat, color: SIMD4<Float>)?
    var textMatrix = CGAffineTransform.identity
    var textDrawingMode = CGTextDrawingMode.fill
    var fontSize: CGFloat = 12
}

private func unpremultipliedColor(_ color: CGColor) -> SIMD4<Float> {
    let c = color.rgba
    return SIMD4(Float(c.0), Float(c.1), Float(c.2), Float(c.3))
}

public final class CGContext: @unchecked Sendable {
    private let base: Surface
    private var layers: [(surface: Surface, state: GState)] = []
    private var state = GState()
    private var stack: [GState] = []
    private var currentPath = CGMutablePath()
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int

    public init?(
        data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
        space: CGColorSpace, bitmapInfo: UInt32
    ) {
        let bitsPerPixel: Int
        let alpha = CGImageAlphaInfo(rawValue: bitmapInfo & 0x1F) ?? .none
        if alpha == .alphaOnly {
            bitsPerPixel = 8
        } else if space.model == .monochrome {
            bitsPerPixel = alpha == .none ? 8 : 16
        } else {
            bitsPerPixel = 32
        }
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              let layout = PixelLayout(bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel, model: alpha == .alphaOnly ? nil : space.model, bitmapInfo: bitmapInfo)
        else { return nil }
        let rowBytes = bytesPerRow == 0 ? width * layout.bytesPerPixel : bytesPerRow
        guard rowBytes >= width * layout.bytesPerPixel else { return nil }
        base = Surface(width: width, height: height, bytesPerRow: rowBytes, layout: layout, data: data?.assumingMemoryBound(to: UInt8.self))
        colorSpace = space
        self.bitmapInfo = CGBitmapInfo(rawValue: bitmapInfo)
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
    }

    // PDF pages aren't written on the web; the page prints instead.
    public init?(consumer: CGDataConsumer, mediaBox: UnsafePointer<CGRect>?, _ auxiliaryInfo: CFDictionary?) { nil }
    public func beginPDFPage(_ info: CFDictionary?) {}
    public func endPDFPage() {}
    public func closePDF() {}
    public func beginPage(mediaBox: UnsafePointer<CGRect>?) {}
    public func endPage() {}

    public var width: Int { base.width }
    public var height: Int { base.height }
    public var bytesPerRow: Int { base.bytesPerRow }
    public var data: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(base.data) }
    public var alphaInfo: CGImageAlphaInfo { CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & 0x1F) ?? .none }

    private var target: Surface { layers.last?.surface ?? base }
    private var flip: CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(base.height)) }
    private var toRaster: CGAffineTransform { state.ctm.concatenating(flip) }
    private var fullBounds: PixelBounds { PixelBounds(x0: 0, y0: 0, x1: base.width, y1: base.height) }

    // MARK: Images

    public func makeImage() -> CGImage? {
        let s = base
        var bytes = [UInt8](repeating: 0, count: s.bytesPerRow * s.height)
        bytes.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: s.data, count: s.bytesPerRow * s.height) }
        if s.isRGBA, s.bytesPerRow == s.width * 4 { return CGImage(rgba: bytes, width: s.width, height: s.height, space: colorSpace) }
        return CGImage(bytes: bytes, width: s.width, height: s.height, bytesPerRow: s.bytesPerRow, layout: s.layout, space: colorSpace, bitmapInfo: bitmapInfo, bitsPerPixel: bitsPerPixel)
    }

    // MARK: State

    public func saveGState() { stack.append(state) }

    public func restoreGState() {
        if let last = stack.popLast() { state = last }
    }

    public var ctm: CGAffineTransform { state.ctm }
    /// The fill colour, straight alpha.
    public var fillColor: SIMD4<Float> { state.fill }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { state.ctm }
    public func translateBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(translationX: x, y: y).concatenating(state.ctm) }
    public func scaleBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(scaleX: x, y: y).concatenating(state.ctm) }
    public func rotate(by angle: CGFloat) { state.ctm = CGAffineTransform(rotationAngle: angle).concatenating(state.ctm) }
    public func concatenate(_ transform: CGAffineTransform) { state.ctm = transform.concatenating(state.ctm) }
    public func convertToDeviceSpace(_ point: CGPoint) -> CGPoint { point.applying(state.ctm) }
    public func convertToDeviceSpace(_ rect: CGRect) -> CGRect { rect.applying(state.ctm) }
    public func convertToUserSpace(_ point: CGPoint) -> CGPoint { point.applying(state.ctm.inverted()) }
    public func convertToUserSpace(_ rect: CGRect) -> CGRect { rect.applying(state.ctm.inverted()) }

    public var interpolationQuality: CGInterpolationQuality {
        get { state.interpolation }
        set { state.interpolation = newValue }
    }

    public func setShouldAntialias(_ value: Bool) { state.antialias = value }
    public func setAllowsAntialiasing(_ value: Bool) {}
    public func setShouldSmoothFonts(_ value: Bool) {}
    public func setAllowsFontSmoothing(_ value: Bool) {}
    public func setShouldSubpixelPositionFonts(_ value: Bool) {}
    public func setRenderingIntent(_ intent: CGColorRenderingIntent) {}
    public func setFlatness(_ flatness: CGFloat) {}
    public func flush() {}
    public func synchronize() {}

    public func setFillColor(_ color: CGColor) { state.fill = unpremultipliedColor(color) }
    public func setStrokeColor(_ color: CGColor) { state.stroke = unpremultipliedColor(color) }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.fill = SIMD4(Float(red), Float(green), Float(blue), Float(alpha)) }
    public func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.stroke = SIMD4(Float(red), Float(green), Float(blue), Float(alpha)) }
    public func setFillColor(gray: CGFloat, alpha: CGFloat) { state.fill = SIMD4(Float(gray), Float(gray), Float(gray), Float(alpha)) }
    public func setStrokeColor(gray: CGFloat, alpha: CGFloat) { state.stroke = SIMD4(Float(gray), Float(gray), Float(gray), Float(alpha)) }
    public func setLineWidth(_ width: CGFloat) { state.lineWidth = width }
    public func setLineCap(_ cap: CGLineCap) { state.lineCap = cap }
    public func setLineJoin(_ join: CGLineJoin) { state.lineJoin = join }
    public func setMiterLimit(_ limit: CGFloat) { state.miterLimit = limit }
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) {
        state.dashPhase = phase
        state.dashLengths = lengths
    }
    public func setAlpha(_ alpha: CGFloat) { state.alpha = min(max(alpha, 0), 1) }
    public func setBlendMode(_ mode: CGBlendMode) { state.blendMode = mode }
    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        guard let color, color.alpha > 0 else {
            state.shadow = nil
            return
        }
        state.shadow = (offset, blur, unpremultipliedColor(color))
    }
    public func setShadow(offset: CGSize, blur: CGFloat) {
        state.shadow = (offset, blur, SIMD4(0, 0, 0, 1.0 / 3.0))
    }
    public var textMatrix: CGAffineTransform {
        get { state.textMatrix }
        set { state.textMatrix = newValue }
    }
    public var textPosition: CGPoint {
        get { CGPoint(x: state.textMatrix.tx, y: state.textMatrix.ty) }
        set {
            state.textMatrix.tx = newValue.x
            state.textMatrix.ty = newValue.y
        }
    }
    public func setTextDrawingMode(_ mode: CGTextDrawingMode) { state.textDrawingMode = mode }
    public func setFontSize(_ size: CGFloat) { state.fontSize = size }
    public func setCharacterSpacing(_ spacing: CGFloat) {}

    // MARK: Path

    public func beginPath() { currentPath = CGMutablePath() }
    public var isPathEmpty: Bool { currentPath.isEmpty }
    public var path: CGPath? { currentPath.isEmpty ? nil : currentPath.copy() }
    public var boundingBoxOfPath: CGRect { currentPath.boundingBoxOfPath }
    public var currentPointOfPath: CGPoint { currentPath.currentPoint }
    public func move(to point: CGPoint) { currentPath.move(to: point, transform: state.ctm) }
    public func addLine(to point: CGPoint) { currentPath.addLine(to: point, transform: state.ctm) }
    public func addLines(between points: [CGPoint]) { currentPath.addLines(between: points, transform: state.ctm) }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) { currentPath.addCurve(to: end, control1: control1, control2: control2, transform: state.ctm) }
    public func addQuadCurve(to end: CGPoint, control: CGPoint) { currentPath.addQuadCurve(to: end, control: control, transform: state.ctm) }
    public func addRect(_ rect: CGRect) { currentPath.addRect(rect, transform: state.ctm) }
    public func addRects(_ rects: [CGRect]) { for r in rects { addRect(r) } }
    public func addEllipse(in rect: CGRect) { currentPath.addEllipse(in: rect, transform: state.ctm) }
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        currentPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise, transform: state.ctm)
    }
    public func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat) {
        currentPath.addArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius, transform: state.ctm)
    }
    public func addPath(_ path: CGPath) { currentPath.addPath(path, transform: state.ctm) }
    public func closePath() { currentPath.closeSubpath() }

    /// The current path, which is kept in device space, in raster space.
    private func takePath() -> [FlatSubpath] {
        let flattened = currentPath.flattened(tolerance: 0.1, transform: flip)
        currentPath = CGMutablePath()
        return flattened
    }

    public func replacePathWithStrokedPath() {
        let stroked = strokePolygons(takeDevicePath())
        currentPath = CGMutablePath()
        for polygon in stroked {
            currentPath.addLines(between: polygon)
            currentPath.closeSubpath()
        }
    }

    private func takeDevicePath() -> [FlatSubpath] {
        let flattened = currentPath.flattened(tolerance: 0.1)
        currentPath = CGMutablePath()
        return flattened
    }

    /// Stroke outlines of device-space polylines, with the line width and
    /// dashes in user space.
    private func strokePolygons(_ deviceSubpaths: [FlatSubpath]) -> [[CGPoint]] {
        // Stroke in user space so non-uniform scales stretch the line as Core Graphics does.
        let inverse = state.ctm.inverted()
        var user = deviceSubpaths.map { FlatSubpath(points: $0.points.map { $0.applying(inverse) }, closed: $0.closed) }
        if !state.dashLengths.isEmpty { user = Stroker.dash(user, phase: state.dashPhase, lengths: state.dashLengths) }
        let width = max(state.lineWidth, 0.0001)
        return Stroker.outline(of: user, width: width, cap: state.lineCap, join: state.lineJoin, miterLimit: state.miterLimit)
            .map { $0.map { $0.applying(state.ctm) } }
    }

    public func fillPath(using rule: CGPathFillRule = .winding) {
        let polygons = takePath().map(\.points)
        paint(polygons, rule: rule, color: state.fill)
    }

    public func eoFillPath() { fillPath(using: .evenOdd) }

    public func strokePath() {
        let polygons = strokePolygons(takeDevicePath()).map { $0.map { $0.applying(flip) } }
        paint(polygons, rule: .winding, color: state.stroke)
    }

    public func drawPath(using mode: CGPathDrawingMode) {
        let path = currentPath.copy()
        switch mode {
        case .fill: fillPath(using: .winding)
        case .eoFill: fillPath(using: .evenOdd)
        case .stroke: strokePath()
        case .fillStroke, .eoFillStroke:
            fillPath(using: mode == .eoFillStroke ? .evenOdd : .winding)
            currentPath = path.mutableCopy()
            strokePath()
        }
    }

    public func fill(_ rect: CGRect) {
        beginPath()
        addRect(rect)
        fillPath()
    }

    public func fill(_ rects: [CGRect]) {
        beginPath()
        addRects(rects)
        fillPath()
    }

    public func fillEllipse(in rect: CGRect) {
        beginPath()
        addEllipse(in: rect)
        fillPath()
    }

    public func stroke(_ rect: CGRect) {
        beginPath()
        addRect(rect)
        strokePath()
    }

    public func stroke(_ rect: CGRect, width: CGFloat) {
        saveGState()
        setLineWidth(width)
        stroke(rect)
        restoreGState()
    }

    public func strokeEllipse(in rect: CGRect) {
        beginPath()
        addEllipse(in: rect)
        strokePath()
    }

    public func strokeLineSegments(between points: [CGPoint]) {
        beginPath()
        var i = 0
        while i + 1 < points.count {
            move(to: points[i])
            addLine(to: points[i + 1])
            i += 2
        }
        strokePath()
    }

    public func clear(_ rect: CGRect) {
        saveGState()
        state.blendMode = .clear
        state.shadow = nil
        state.alpha = 1
        fill(rect)
        restoreGState()
    }

    // MARK: Clipping

    public func clip(using rule: CGPathFillRule = .winding) {
        let polygons = takePath().map(\.points)
        clip(polygons: polygons, rule: rule)
    }

    public func clip() { clip(using: .winding) }
    public func eoClip() { clip(using: .evenOdd) }

    public func clip(to rect: CGRect) {
        let t = toRaster
        let r = rect.standardized
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
        // A pixel-aligned rectangle needs no mask.
        if t.b == 0, t.c == 0, corners.allSatisfy({ abs($0.x - $0.x.rounded()) < 1e-6 && abs($0.y - $0.y.rounded()) < 1e-6 }), state.clip?.mask == nil {
            let bounds = PixelBounds(covering: CGRect(origin: corners[0], size: .zero).union(CGRect(origin: corners[2], size: .zero)))
            state.clip = Clip(bounds: (state.clip?.bounds ?? fullBounds).intersection(bounds), mask: nil)
            return
        }
        clip(polygons: [corners], rule: .winding)
    }

    public func clip(to rects: [CGRect]) {
        let t = toRaster
        let polygons = rects.map { r in
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
        }
        clip(polygons: polygons, rule: .winding)
    }

    public func clip(to rect: CGRect, mask: CGImage) {
        let paint = ImagePaint(image: maskImage(mask), toRaster: imageTransform(rect), quality: state.interpolation)
        let t = toRaster
        let r = rect.standardized
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
        let current = state.clip ?? Clip(bounds: fullBounds, mask: nil)
        let area = PixelBounds(covering: corners.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) })
        state.clip = current.intersecting(bounds: area) { values, b in
            let w = b.x1 - b.x0
            Rasterizer.rasterize([corners], rule: .winding, bounds: b, antialias: state.antialias) { y, x0, coverage in
                for i in 0..<coverage.count {
                    let x = x0 + i
                    values[(y - b.y0) * w + (x - b.x0)] = coverage[i] * paint.sample(x, y).w
                }
            }
        }
    }

    public func resetClip() { state.clip = nil }

    public var boundingBoxOfClipPath: CGRect {
        let b = state.clip?.bounds ?? fullBounds
        let device = CGRect(x: b.x0, y: base.height - b.y1, width: b.x1 - b.x0, height: b.y1 - b.y0)
        return device.applying(state.ctm.inverted())
    }

    private func clip(polygons: [[CGPoint]], rule: CGPathFillRule) {
        let current = state.clip ?? Clip(bounds: fullBounds, mask: nil)
        state.clip = current.intersecting(bounds: current.bounds) { values, b in
            let w = b.x1 - b.x0
            Rasterizer.rasterize(polygons, rule: rule, bounds: b, antialias: state.antialias) { y, x0, coverage in
                for i in 0..<coverage.count { values[(y - b.y0) * w + (x0 + i - b.x0)] = coverage[i] }
            }
        }
    }

    /// A mask image as alpha-only pixels: grey values and image masks become coverage.
    private func maskImage(_ image: CGImage) -> CGImage {
        let values = image.maskValues
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for i in 0..<values.count { rgba[i * 4 + 3] = values[i] }
        return CGImage(rgba: rgba, width: image.width, height: image.height, space: nil)
    }

    // MARK: Drawing

    /// Image pixel space (rows top first) to raster space, for an image drawn in `rect`.
    private func imageTransform(_ rect: CGRect, imageWidth: Int? = nil, imageHeight: Int? = nil, image: CGImage? = nil) -> CGAffineTransform {
        let w = CGFloat(imageWidth ?? image?.width ?? 1), h = CGFloat(imageHeight ?? image?.height ?? 1)
        let r = rect
        let toUser = CGAffineTransform(a: r.width / w, b: 0, c: 0, d: -r.height / h, tx: r.minX, ty: r.maxY)
        return toUser.concatenating(toRaster)
    }

    public func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false) {
        guard rect.width != 0, rect.height != 0 else { return }
        let t = imageTransform(rect, imageWidth: image.width, imageHeight: image.height)
        let paint = ImagePaint(image: image, toRaster: t, quality: state.interpolation, tiled: byTiling)
        let polygon: [[CGPoint]]
        if byTiling {
            let b = state.clip?.bounds ?? fullBounds
            polygon = [[CGPoint(x: b.x0, y: b.y0), CGPoint(x: b.x1, y: b.y0), CGPoint(x: b.x1, y: b.y1), CGPoint(x: b.x0, y: b.y1)]]
        } else {
            polygon = [[CGPoint(x: 0, y: 0), CGPoint(x: image.width, y: 0), CGPoint(x: image.width, y: image.height), CGPoint(x: 0, y: image.height)].map { $0.applying(t) }]
        }
        if image.isMask {
            // An image mask paints the fill colour through it.
            let fill = state.fill
            let color = SIMD4(fill.x * fill.w, fill.y * fill.w, fill.z * fill.w, fill.w)
            composite(polygon, rule: .winding, paint: .gradient({ x, y in color * paint.sample(x, y).w }))
            return
        }
        composite(polygon, rule: .winding, paint: .image(paint))
    }

    public func drawLinearGradient(_ gradient: CGGradient, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        let inverse = toRaster.inverted()
        let dx = end.x - start.x, dy = end.y - start.y
        let length2 = dx * dx + dy * dy
        let before = options.contains(.drawsBeforeStartLocation), after = options.contains(.drawsAfterEndLocation)
        let b = state.clip?.bounds ?? fullBounds
        let polygon = [[CGPoint(x: b.x0, y: b.y0), CGPoint(x: b.x1, y: b.y0), CGPoint(x: b.x1, y: b.y1), CGPoint(x: b.x0, y: b.y1)]]
        composite(polygon, rule: .winding, paint: .gradient({ x, y in
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
            var t = length2 > 0 ? Double(((p.x - start.x) * dx + (p.y - start.y) * dy) / length2) : 0
            if t < 0 { if !before { return nil }; t = 0 }
            if t > 1 { if !after { return nil }; t = 1 }
            return gradient.color(at: t)
        }))
    }

    public func drawRadialGradient(
        _ gradient: CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat,
        options: CGGradientDrawingOptions
    ) {
        let inverse = toRaster.inverted()
        let before = options.contains(.drawsBeforeStartLocation), after = options.contains(.drawsAfterEndLocation)
        let b = state.clip?.bounds ?? fullBounds
        let polygon = [[CGPoint(x: b.x0, y: b.y0), CGPoint(x: b.x1, y: b.y0), CGPoint(x: b.x1, y: b.y1), CGPoint(x: b.x0, y: b.y1)]]
        let cdx = Double(endCenter.x - startCenter.x), cdy = Double(endCenter.y - startCenter.y), dr = Double(endRadius - startRadius)
        let r0 = Double(startRadius)
        let a = cdx * cdx + cdy * cdy - dr * dr
        composite(polygon, rule: .winding, paint: .gradient({ x, y in
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
            let px = Double(p.x - startCenter.x), py = Double(p.y - startCenter.y)
            // Solve for the largest t whose circle passes through p.
            let bq = px * cdx + py * cdy + r0 * dr
            let c = px * px + py * py - r0 * r0
            var t: Double
            if abs(a) < 1e-9 {
                guard abs(bq) > 1e-12 else { return nil }
                t = c / (2 * bq)
            } else {
                let disc = bq * bq - a * c
                guard disc >= 0 else { return nil }
                let root = sqrt(disc)
                t = (bq + root) / a
                if r0 + t * dr < 0 { t = (bq - root) / a }
            }
            guard r0 + t * dr >= 0 else { return nil }
            if t < 0 { if !before { return nil }; t = 0 }
            if t > 1 { if !after { return nil }; t = 1 }
            return gradient.color(at: t)
        }))
    }

    // MARK: Transparency layers

    public func beginTransparencyLayer(auxiliaryInfo: CFDictionary?) {
        layers.append((Surface(width: base.width, height: base.height), state))
        state.alpha = 1
        state.blendMode = .normal
        state.shadow = nil
    }

    public func beginTransparencyLayer(in rect: CGRect, auxiliaryInfo: CFDictionary?) {
        beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo)
    }

    public func endTransparencyLayer() {
        guard let (surface, saved) = layers.popLast() else { return }
        let inner = state
        state = saved
        let b = state.clip?.bounds ?? fullBounds
        let polygon = [[CGPoint(x: b.x0, y: b.y0), CGPoint(x: b.x1, y: b.y0), CGPoint(x: b.x1, y: b.y1), CGPoint(x: b.x0, y: b.y1)]]
        composite(polygon, rule: .winding, paint: .surface(surface, dx: 0, dy: 0))
        state.ctm = saved.ctm
        _ = inner
    }

    // MARK: Compositing

    private func paint(_ polygons: [[CGPoint]], rule: CGPathFillRule, color: SIMD4<Float>) {
        let premultiplied = SIMD4(color.x * color.w, color.y * color.w, color.z * color.w, color.w)
        composite(polygons, rule: rule, paint: .solid(premultiplied))
    }

    /// Draws coverage of `polygons` (raster space) filled from `paint`, with
    /// the current alpha, blend mode, clip and shadow.
    private func composite(_ polygons: [[CGPoint]], rule: CGPathFillRule, paint: Paint) {
        if let shadow = state.shadow {
            // The shape alone, moved to where its shadow falls, as it may be
            // drawn off the surface for only its shadow to show.
            let dx = Int(shadow.offset.width.rounded()), dy = Int((-shadow.offset.height).rounded())
            let shape = Surface(width: base.width, height: base.height)
            let saved = state
            state.shadow = nil
            state.blendMode = .normal
            state.alpha = 1
            let clip = state.clip
            state.clip = nil
            let moved = polygons.map { $0.map { CGPoint(x: $0.x + CGFloat(dx), y: $0.y + CGFloat(dy)) } }
            render(moved, rule: rule, paint: paint.moved(dx: dx, dy: dy), into: shape)
            state = saved
            state.clip = clip
            var alpha = [Float](repeating: 0, count: shape.width * shape.height)
            for y in 0..<shape.height {
                for x in 0..<shape.width { alpha[y * shape.width + x] = shape.read(x, y).w }
            }
            gaussianBlur(&alpha, width: shape.width, height: shape.height, sigma: Double(shadow.blur) / 2)
            let c = shadow.color
            let color = SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
            let w = shape.width, h = shape.height
            let everything = [[CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]]
            state.shadow = nil
            render(everything, rule: .winding, paint: .gradient({ x, y in
                guard x >= 0, y >= 0, x < w, y < h else { return nil }
                return color * alpha[y * w + x]
            }), into: target)
            render(polygons, rule: rule, paint: paint, into: target)
            state.shadow = shadow
            return
        }
        render(polygons, rule: rule, paint: paint, into: target)
    }

    private func render(_ polygons: [[CGPoint]], rule: CGPathFillRule, paint: Paint, into surface: Surface) {
        let clip = state.clip
        let bounds = (clip?.bounds ?? fullBounds).intersection(PixelBounds(x0: 0, y0: 0, x1: surface.width, y1: surface.height))
        guard !bounds.isEmpty else { return }
        let alpha = Float(state.alpha)
        let mode = state.blendMode
        // Modes that change the backdrop where the source is clear must
        // touch every pixel the clip allows, not just the shape's.
        let unbounded = [.copy, .sourceIn, .destinationIn, .sourceOut, .destinationAtop, .clear].contains(mode)
        var shapePolygons = polygons
        if unbounded, mode != .clear {
            shapePolygons = [[CGPoint(x: bounds.x0, y: bounds.y0), CGPoint(x: bounds.x1, y: bounds.y0), CGPoint(x: bounds.x1, y: bounds.y1), CGPoint(x: bounds.x0, y: bounds.y1)]]
        }
        // Where an unbounded mode's source is outside the shape, it's clear.
        var inside: [Float]? = nil
        if unbounded, mode != .clear {
            let w = bounds.x1 - bounds.x0
            var values = [Float](repeating: 0, count: w * (bounds.y1 - bounds.y0))
            Rasterizer.rasterize(polygons, rule: rule, bounds: bounds, antialias: state.antialias) { y, x0, coverage in
                for i in 0..<coverage.count { values[(y - bounds.y0) * w + (x0 + i - bounds.x0)] = coverage[i] }
            }
            inside = values
        }
        let w = bounds.x1 - bounds.x0
        Rasterizer.rasterize(shapePolygons, rule: rule, bounds: bounds, antialias: state.antialias) { y, x0, coverage in
            for i in 0..<coverage.count {
                let x = x0 + i
                var c = coverage[i]
                if let clip { c *= clip.value(x, y) }
                guard c > 0 else { continue }
                var source: SIMD4<Float>
                if let inside {
                    let shape = inside[(y - bounds.y0) * w + (x - bounds.x0)]
                    source = shape > 0 ? (paint.color(x, y) ?? .zero) * (alpha * shape) : .zero
                } else {
                    guard let color = paint.color(x, y) else { continue }
                    source = color * alpha
                }
                let destination = surface.read(x, y)
                if mode == .normal, c == 1 {
                    if source.w >= 1 { surface.write(x, y, source); continue }
                    if source.w <= 0 { continue }
                }
                let out = blend(mode, source, destination)
                surface.write(x, y, c >= 1 ? out : destination + (out - destination) * c)
            }
        }
    }
}
