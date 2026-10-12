import CoreGraphics
import Foundation

/// A saved arrangement of the picture's layers — which show, where they
/// sit and how they mix — to come back to, or to export each as a picture.
struct LayerComp: Identifiable, Codable, Equatable, Sendable {
    struct LayerState: Codable, Equatable, Sendable {
        var isVisible: Bool
        var opacity: Double
        var blendMode: LayerBlendMode
        var transform: LayerTransform
        /// The size of the layer's pixels then, which its placement suits.
        var imageSize: CGSize?
    }

    var id = UUID()
    var name: String
    /// Each layer's state when the comp was made, by layer.
    var states: [UUID: LayerState]
}

extension Composition {
    /// The layers as they are now, as a comp.
    func layerComp(named name: String) -> LayerComp {
        LayerComp(name: name, states: Dictionary(uniqueKeysWithValues: layers.map { layer in
            (layer.id, LayerComp.LayerState(
                isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode, transform: layer.transform,
                imageSize: layer.image.size
            ))
        }))
    }

    /// The picture with a comp's arrangement put back. Layers made since
    /// the comp keep how they are.
    func applying(_ comp: LayerComp) -> Composition {
        var copy = self
        for index in copy.layers.indices {
            guard let state = comp.states[copy.layers[index].id] else { continue }
            copy.layers[index].isVisible = state.isVisible
            copy.layers[index].opacity = state.opacity
            copy.layers[index].blendMode = state.blendMode
            // A layer painted on since is canvas-sized now; where it sat
            // before no longer fits it.
            if state.imageSize.map({ $0 == copy.layers[index].image.size }) ?? true {
                copy.layers[index].transform = state.transform
            }
        }
        return copy
    }

    /// A name nobody has used yet: "Comp 2" after "Comp 1".
    func nextLayerCompName() -> String {
        let base = String(localized: "Comps.DefaultName")
        let names = Set(layerComps.map(\.name))
        var number = layerComps.count + 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

/// Pictures written out as PNG files in a fresh temporary folder, to share.
enum ImageFiles {
    static func write(_ images: [(name: String, image: CGImage)]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        return try images.map { item in
            var stem = item.name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            if stem.trimmingCharacters(in: .whitespaces).isEmpty { stem = String(localized: "Export.DefaultName") }
            var unique = stem, number = 2
            while !used.insert(unique).inserted {
                unique = "\(stem) \(number)"
                number += 1
            }
            let url = folder.appending(path: "\(unique).png")
            try ImageCodec.encode(item.image, as: .png).write(to: url, options: .atomic)
            return url
        }
    }
}
