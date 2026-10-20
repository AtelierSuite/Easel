import CoreGraphics
import Foundation

/// A tile repeated to fill an area: one of the built-in ones drawn in a
/// colour, or one made from part of a picture and kept with it.
package struct PatternChoice: Codable, Hashable, Sendable {
    package enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case dots, stripes, checker, grid, diagonal, waves

        package var id: String { rawValue }
        package var labelKey: String { "Pattern.\(rawValue.capitalized)" }
        package var symbolName: String {
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
    package var preset: Preset? = .dots
    package var swatchID: UUID?
    /// The built-in tile's colour, on transparency.
    package var color: RGBAColor = .black
    /// How large each tile is, as a multiple of its own size.
    package var scale = 1.0
    /// A picture's own tile carried along as PNG, for shapes that are drawn
    /// without the picture's swatches to hand.
    package var tileData: Data?

    package init(
        preset: Preset? = .dots,
        swatchID: UUID? = nil,
        color: RGBAColor = .black,
        scale: Double = 1.0,
        tileData: Data? = nil
    ) {
        self.preset = preset
        self.swatchID = swatchID
        self.color = color
        self.scale = scale
        self.tileData = tileData
    }

    /// The tile at its own size, or nil if its swatch is gone.
    package func tile(in swatches: [PatternSwatch]) -> CGImage? {
        if let preset { return Self.presetTile(preset, color: color) }
        if let swatch = swatches.first(where: { $0.id == swatchID }) { return swatch.image.cgImage }
        return tileData.flatMap { try? ImageCodec.decode($0) }
    }

    /// The same pattern, carrying its tile with it if it is the picture's own.
    package func carryingTile(from swatches: [PatternSwatch]) -> PatternChoice {
        guard preset == nil, let swatch = swatches.first(where: { $0.id == swatchID }) else { return self }
        var copy = self
        copy.tileData = try? swatch.image.pngData()
        return copy
    }

    package static let presetSize = 24.0

    package static func presetTile(_ preset: Preset, color: RGBAColor) -> CGImage {
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
    package func draw(in context: CGContext, rect: CGRect, swatches: [PatternSwatch]) {
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
package struct PatternSwatch: Identifiable, Equatable, Sendable {
    package var id = UUID()
    package var name: String
    package var image: LayerImage
    /// The id a Photoshop file it came from knows it by, which that file's
    /// styles and fills name it with.
    package var photoshopID: String?

    package init(id: UUID = UUID(), name: String, image: LayerImage, photoshopID: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.photoshopID = photoshopID
    }
}
