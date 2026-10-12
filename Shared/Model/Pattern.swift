import CoreGraphics
import Foundation

/// A tile repeated to fill an area: one of the built-in ones drawn in a
/// colour, or one made from part of a picture and kept with it.
struct PatternChoice: Codable, Hashable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case dots, stripes, checker, grid, diagonal, waves

        var id: String { rawValue }
        var labelKey: String { "Pattern.\(rawValue.capitalized)" }
        var symbolName: String {
            switch self {
            case .dots: return "circle.grid.3x3"
            case .stripes: return "line.3.horizontal"
            case .checker: return "checkerboard.rectangle"
            case .grid: return "grid"
            case .diagonal: return "line.diagonal"
            case .waves: return "water.waves"
            }
        }
    }

    /// A built-in tile, or nil for the picture's own pattern `swatchID`.
    var preset: Preset? = .dots
    var swatchID: UUID?
    /// The built-in tile's colour, on transparency.
    var color: RGBAColor = .black
    /// How large each tile is, as a multiple of its own size.
    var scale = 1.0

    /// The tile at its own size, or nil if its swatch is gone.
    func tile(in swatches: [PatternSwatch]) -> CGImage? {
        if let preset { return Self.presetTile(preset, color: color) }
        return swatches.first { $0.id == swatchID }?.image.cgImage
    }

    static let presetSize = 24.0

    static func presetTile(_ preset: Preset, color: RGBAColor) -> CGImage {
        let size = presetSize
        return Bitmap.render(size: CGSize(width: size, height: size)) { context in
            context.setFillColor(color.cgColor)
            context.setStrokeColor(color.cgColor)
            switch preset {
            case .dots:
                context.fillEllipse(in: CGRect(x: size * 0.3, y: size * 0.3, width: size * 0.4, height: size * 0.4))
            case .stripes:
                context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
            case .checker:
                context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
                context.fill(CGRect(x: size / 2, y: size / 2, width: size / 2, height: size / 2))
            case .grid:
                context.fill(CGRect(x: 0, y: 0, width: size, height: 2))
                context.fill(CGRect(x: 0, y: 0, width: 2, height: size))
            case .diagonal:
                // Corner to corner, wrapping, so tiles meet in one line.
                context.setLineWidth(size * 0.18)
                for offset in [-size, 0, size] {
                    context.move(to: CGPoint(x: offset, y: size))
                    context.addLine(to: CGPoint(x: offset + size, y: 0))
                }
                context.strokePath()
            case .waves:
                context.setLineWidth(size * 0.12)
                context.move(to: CGPoint(x: 0, y: size / 2))
                context.addCurve(to: CGPoint(x: size, y: size / 2),
                                 control1: CGPoint(x: size / 3, y: size * 0.1), control2: CGPoint(x: size * 2 / 3, y: size * 0.9))
                context.strokePath()
            }
        }
    }

    /// Fills `rect` of `context` — in canvas coordinates, y down — with the
    /// tile repeated from the canvas's top left.
    func draw(in context: CGContext, rect: CGRect, swatches: [PatternSwatch]) {
        guard let tile = tile(in: swatches) else { return }
        let width = Double(tile.width) * max(scale, 0.05), height = Double(tile.height) * max(scale, 0.05)
        let firstColumn = Int((rect.minX / width).rounded(.down)), lastColumn = Int((rect.maxX / width).rounded(.up))
        let firstRow = Int((rect.minY / height).rounded(.down)), lastRow = Int((rect.maxY / height).rounded(.up))
        // Too many tiles to lay one by one: nothing that small shows anyway.
        guard (lastColumn - firstColumn) * (lastRow - firstRow) < 250_000 else { return }
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                Bitmap.draw(tile, in: CGRect(x: Double(column) * width, y: Double(row) * height, width: width, height: height), context: context)
            }
        }
    }
}

/// A pattern tile made from part of a picture, kept with it.
struct PatternSwatch: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var image: LayerImage
}
