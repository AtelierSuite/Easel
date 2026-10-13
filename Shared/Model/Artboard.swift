import CoreGraphics
import Foundation

/// A named part of the canvas exported as a picture of its own, so one
/// document can hold several designs side by side.
struct Artboard: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// In canvas pixels.
    var rect: CGRect
}

extension Composition {
    /// A name nobody has used yet: "Artboard 2" after "Artboard 1".
    func nextArtboardName() -> String {
        let base = String(localized: "Artboards.DefaultName")
        let names = Set(artboards.map(\.name))
        var number = artboards.count + 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// What an artboard shows, at its own size.
    func render(_ artboard: Artboard, background: RGBAColor? = nil) -> CGImage {
        let rect = artboard.rect.integral
        return Bitmap.render(size: rect.size) { context in
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(origin: .zero, size: rect.size))
            }
            context.translateBy(x: -rect.minX, y: -rect.minY)
            CompositionRenderer.draw(CompositionRenderer.drawnLayers(self), in: context)
        }
    }
}
