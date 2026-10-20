import CoreGraphics
import Foundation

/// A named part of the canvas exported as a picture of its own, so one
/// document can hold several designs side by side.
package struct Artboard: Identifiable, Codable, Equatable, Sendable {
    package var id = UUID()
    package var name: String
    /// In canvas pixels.
    package var rect: CGRect
    /// The group holding its layers, for an artboard from Photoshop, where
    /// artboards are groups.
    package var groupID: UUID?

    package init(id: UUID = UUID(), name: String, rect: CGRect, groupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.rect = rect
        self.groupID = groupID
    }
}

extension Composition {
    /// A name nobody has used yet: "Artboard 2" after "Artboard 1".
    package func nextArtboardName() -> String {
        let base = String(localized: "Artboards.DefaultName")
        let names = Set(artboards.map(\.name))
        var number = artboards.count + 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// What an artboard shows, at its own size.
    package func render(_ artboard: Artboard, background: RGBAColor? = nil) -> CGImage {
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
