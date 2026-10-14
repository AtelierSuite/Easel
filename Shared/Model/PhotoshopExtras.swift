import Foundation

/// What a layer from a Photoshop file had that Easel does not use, kept
/// byte for byte so saving back to Photoshop loses none of it.
///
/// Some of it describes the layer's content — its text, vector shape or
/// fill — which Photoshop would draw again from it. Those are kept only
/// while the layer is as it was read: once its pixels, mask, placement or
/// filters change they no longer match, and Photoshop gets the pixels alone.
struct PhotoshopExtras: Codable, Equatable, Sendable {
    struct Block: Codable, Equatable, Sendable {
        var key: String
        var data: Data
    }

    /// Tagged blocks in the order they came.
    var blocks: [Block] = []
    /// The layer's blend-if ranges.
    var blendingRanges: Data?
    /// The mask's density and feather: a byte saying which follow, then them.
    var maskParameters: Data?
    /// The layer as it was read, which content blocks describe.
    var source: Source?

    struct Source: Codable, Equatable, Sendable {
        var image: UUID
        var mask: UUID?
        var transform: LayerTransform
        var filters: [LayerFilter]
    }

    /// Blocks that say what the layer shows, which only hold while it does.
    static let contentKeys: Set<String> = [
        "TySh", "tySh", "SoCo", "GdFl", "PtFl", "vscg", "vstk", "vmsk", "vsms", "vogk", "vmgm", "anFX",
    ]

    init(blocks: [Block] = [], blendingRanges: Data? = nil, maskParameters: Data? = nil, source: Source? = nil) {
        self.blocks = blocks
        self.blendingRanges = blendingRanges
        self.maskParameters = maskParameters
        self.source = source
    }

    /// The blocks still true of `layer`.
    func blocks(for layer: Layer) -> [Block] {
        let current = source.map { source in
            source.image == layer.image.id && source.mask == layer.mask?.image.id
                && source.transform == layer.transform && source.filters == layer.filters
        } ?? false
        return current ? blocks : blocks.filter { !Self.contentKeys.contains($0.key) }
    }
}

/// What a Photoshop document had beyond its layers that Easel does not use:
/// image resources and tagged blocks for the whole document.
struct PhotoshopDocumentExtras: Equatable, Sendable {
    struct Resource: Equatable, Sendable {
        var id: Int
        var name: [UInt8]
        var data: Data
    }

    var resources: [Resource] = []
    var blocks: [PhotoshopExtras.Block] = []
}
