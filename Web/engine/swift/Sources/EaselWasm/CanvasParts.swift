import CoreGraphics
import Foundation
import Paintbrush

/// The picture cut into the few images the page's GPU canvas mixes, so a
/// stroke redraws only the layer it lands on. Runs of normal layers are
/// flattened together, as mixing them one by one gives the same picture;
/// the layer being painted, and each layer in another mode, stand alone
/// with their mode and opacity left for the GPU. Everything up to the last
/// adjustment layer is flattened, as the GPU can't adjust what's beneath.
struct CanvasParts {
    struct Part {
        var layers: [Layer]
        var blendMode: LayerBlendMode
        var opacity: Double
        var isActive: Bool
    }

    let parts: [Part]
    /// Which part holds the layer being painted; nil when it can't stand
    /// alone (under an adjustment, or inside a group that doesn't pass
    /// through), and strokes are only shown over the picture until painted.
    let activeIndex: Int?

    init(_ composition: Composition, active: Layer.ID?) {
        let units = CompositionRenderer.drawnLayers(composition).clippingUnits
            .filter { $0.base.isVisible && $0.base.opacity > 0 }
        var activeUnit = units.firstIndex { unit in unit.base.id == active || unit.clipped.contains { $0.id == active } }
        let lastAdjustment = units.lastIndex { $0.base.isAdjustment }
        if let unit = activeUnit, let last = lastAdjustment, unit <= last { activeUnit = nil }

        var parts: [Part] = []
        var run: [Layer] = []
        var activeIndex: Int?
        func flush() {
            guard !run.isEmpty else { return }
            parts.append(Part(layers: run, blendMode: .normal, opacity: 1, isActive: false))
            run = []
        }
        for (index, unit) in units.enumerated() {
            let layers = [unit.base] + unit.clipped
            let flattened = lastAdjustment.map { index <= $0 } ?? false
            if flattened || (index != activeUnit && unit.base.blendMode == .normal) {
                run += layers
                continue
            }
            flush()
            if index == activeUnit { activeIndex = parts.count }
            parts.append(Part(
                layers: [unit.base.with(opacity: 1, blendMode: .normal)] + unit.clipped,
                blendMode: unit.base.blendMode, opacity: unit.base.opacity, isActive: index == activeUnit
            ))
        }
        flush()
        self.parts = parts
        self.activeIndex = activeIndex
    }

    /// What the page compares to tell whether the parts it holds still fit.
    var key: String {
        parts.map { part in
            part.layers.map(\.id.uuidString).joined(separator: ",") + (part.isActive ? "!" : "") + ":\(part.blendMode.rawValue)"
        }.joined(separator: "|")
    }

    /// The canvas's size as shown: no larger than `maxSize` along its longer side.
    static func size(of composition: Composition, maxSize: Int) -> CGSize {
        let longest = max(composition.size.width, composition.size.height)
        let factor = min(1, Double(maxSize) / longest)
        return CGSize(
            width: max(1, (composition.size.width * factor).rounded()),
            height: max(1, (composition.size.height * factor).rounded())
        )
    }

    /// One part drawn alone at `size`, premultiplied RGBA, as the GPU mixes it.
    static func pixels(of part: Part, in composition: Composition, size: CGSize) -> Data {
        let image = Bitmap.render(size: size) { context in
            context.scaleBy(x: size.width / composition.size.width, y: size.height / composition.size.height)
            CompositionRenderer.draw(part.layers, in: context, scale: size.width / composition.size.width)
        }
        return Data(image.rgba)
    }

    func describe() -> [[String: Any]] {
        parts.map { ["blendMode": $0.blendMode.rawValue, "opacity": $0.opacity, "active": $0.isActive] }
    }
}
