import Foundation

/// What a layer from a Photoshop file had that Easel does not use, kept
/// byte for byte so saving back to Photoshop loses none of it.
///
/// Some of it describes the layer's content — its text, vector shape or
/// fill — which Photoshop would draw again from it. Those are kept only
/// while the layer is as it was read: once its pixels, mask, placement or
/// filters change they no longer match, and Photoshop gets the pixels alone.
package struct PhotoshopExtras: Codable, Equatable, Sendable {
    package struct Block: Codable, Equatable, Sendable {
        package var key: String
        package var data: Data
    }

    /// Tagged blocks in the order they came.
    package var blocks: [Block] = []
    /// The layer's blend-if ranges.
    package var blendingRanges: Data?
    /// The mask's density and feather: a byte saying which follow, then them.
    package var maskParameters: Data?
    /// The layer as it was read, which content blocks describe.
    package var source: Source?
    /// Photoshop's own record of the layer's styles, adjustment or smart
    /// object, which say more than Easel keeps of them: written back while
    /// what Easel made of them is unchanged.
    package var effects: Kept<[LayerEffect]>?
    package var adjustment: Kept<LayerFilter>?
    package var smartObject: Kept<SmartObjectState>?
    /// The layer's id in the file, which its comps' settings name it by.
    package var layerID: UInt32?
    /// Its `shmd` metadata as it came — how each comp shows it, its time,
    /// any animation — and the layer as it was then, which that holds true of.
    package var metadata: Kept<CompState>?

    /// A group's closing divider's own id and metadata, which Photoshop
    /// keeps apart from the group's.
    package var divider: Divider?

    package struct Divider: Codable, Equatable, Sendable {
        package var layerID: UInt32?
        package var metadata: Data?
    }

    /// What comps' settings for a layer are measured from.
    package struct CompState: Codable, Equatable, Sendable {
        package var isVisible: Bool
        package var opacity: Double
        /// For a group, nil passing through.
        package var blendMode: LayerBlendMode?
    }

    package struct Kept<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        package var blocks: [Block]
        /// What Easel made of them, and where the layer was then.
        package var value: Value
        package var transform: LayerTransform
    }

    /// What a smart object's blocks hold true of: the pixels it showed,
    /// how they were bent and the link it waited for. The contents drawn
    /// again give new pixels.
    package struct SmartObjectState: Codable, Equatable, Sendable {
        package var image: UUID
        package var warp: SmartObjectWarp?
        package var missingLink: SmartObjectLink?
        /// Its entry in the document's embedded or linked files, as it was.
        package var entry: Data?
    }

    package struct Source: Codable, Equatable, Sendable {
        package var image: UUID
        package var mask: UUID?
        package var transform: LayerTransform
        package var filters: [LayerFilter]
    }

    /// Blocks that say what the layer shows, which only hold while it does.
    package static let contentKeys: Set<String> = [
        "TySh", "tySh", "SoCo", "GdFl", "PtFl", "vscg", "vstk", "vmsk", "vsms", "vogk", "vmgm", "anFX",
    ]

    package init(blocks: [Block] = [], blendingRanges: Data? = nil, maskParameters: Data? = nil, source: Source? = nil) {
        self.blocks = blocks
        self.blendingRanges = blendingRanges
        self.maskParameters = maskParameters
        self.source = source
    }

    /// The styles as Photoshop had them, while Easel's are as read. Pattern
    /// overlays name their tiles by Photoshop's ids, which the file's own
    /// pattern tiles are written back with.
    package func effectBlocks(for layer: Layer) -> [Block]? {
        guard let effects, effects.value == layer.effects, effects.transform == layer.transform else { return nil }
        return effects.blocks
    }

    package func adjustmentBlocks(for layer: Layer) -> [Block]? {
        guard let adjustment, adjustment.value == layer.adjustment else { return nil }
        return adjustment.blocks
    }

    /// The smart object as Photoshop had it, while nothing about it has
    /// changed: no new contents, placement, bend or filters.
    package func smartObjectBlocks(for layer: Layer) -> (blocks: [Block], entry: Data?)? {
        guard let smartObject, smartObject.transform == layer.transform, layer.filters.isEmpty,
              smartObject.value.image == layer.image.id, smartObject.value.warp == layer.smartObject?.warp,
              smartObject.value.missingLink == layer.missingLink else { return nil }
        return (smartObject.blocks, smartObject.value.entry)
    }

    /// The blocks still true of `layer`.
    package func blocks(for layer: Layer) -> [Block] {
        let current = source.map { source in
            source.image == layer.image.id && source.mask == layer.mask?.image.id
                && source.transform == layer.transform && source.filters == layer.filters
        } ?? false
        return current ? blocks : blocks.filter { !Self.contentKeys.contains($0.key) }
    }
}

/// What a Photoshop document had beyond its layers that Easel does not use:
/// image resources and tagged blocks for the whole document.
package struct PhotoshopDocumentExtras: Equatable, Sendable {
    package struct Resource: Equatable, Sendable {
        package var id: Int
        package var name: [UInt8]
        package var data: Data
    }

    package var resources: [Resource] = []
    package var blocks: [PhotoshopExtras.Block] = []
    /// Its pattern tiles as they were, `Patt`, `Pat2` and `Pat3`, which its
    /// styles and fills name by id: written back so those still find them.
    package var patternBlocks: [PhotoshopExtras.Block] = []
    /// The ICC profile its colours were in, which they go back to.
    package var colorProfile: Data?
    /// What of the file Easel could not keep, so would not write back:
    /// empty when the file can be edited where it is.
    package var losses: Set<WriteBackLoss> = []
    /// Its layer comps as Photoshop listed them, to write back while
    /// Easel's are as read.
    package var comps: KeptComps?

    package struct KeptComps: Equatable, Sendable {
        /// The `CompList` resource as it came.
        package var resource: Data
        /// What Easel made of the comps.
        package var value: [LayerComp]
        /// The number Photoshop knew each comp by, which layers' settings
        /// name it with.
        package var ids: [UUID: Int32]
    }
}
