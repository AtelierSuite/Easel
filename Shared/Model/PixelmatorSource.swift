import Foundation

/// Where a layer came from in a Pixelmator Pro document, so the document can
/// be written back in place changing only what was edited.
struct PixelmatorSource: Equatable, Sendable {
    /// The layer's identifier in the document's layer table.
    var identifier: String
    /// The pixels as they were read. Every edit makes a new image, so a
    /// layer still showing this one has pixels the document already holds.
    var image: LayerImage?
    /// The layer's bitmap mask in the document, and its pixels as read.
    var maskIdentifier: String?
    var mask: LayerImage?
    /// A colour adjustments layer's filter as it was read.
    var adjustment: LayerFilter?
    /// Set on Pixelmator's own preview, brought in to compare against: it is
    /// not part of the document, and is written back only once painted on.
    var isPreview = false
}
