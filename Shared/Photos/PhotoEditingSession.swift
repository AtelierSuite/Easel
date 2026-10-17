import CoreGraphics
import Foundation
@preconcurrency import Photos
import Paintbrush
import UniformTypeIdentifiers

/// Editing a photo where it lies in the library: reading it in, layers and
/// all if Easel edited it before, and writing the edit back as Photos
/// expects, with the layers riding along as adjustment data.
///
/// Used both by the app, for photos opened from the library, and by the
/// editing extension inside the Photos app.
///
/// Unchecked: `PHContentEditingInput` is not marked sendable, but nothing in
/// it changes after Photos hands it over, and it is only ever read.
struct PhotoEditingSession: @unchecked Sendable {
    static let formatIdentifier = "com.tsubuzaki.Easel"
    static let formatVersion = "2"

    let input: PHContentEditingInput
    /// The photo as it came, kept so a layer still showing it untouched is
    /// recorded as a reference instead of a copy of its pixels.
    let original: LayerImage
    let composition: Composition
    /// Whether the composition came back from an earlier Easel edit.
    let isResumed: Bool

    /// The layers saved with the edit this session started from, which a
    /// new edit replaces.
    var previousPayload: Data? {
        guard let data = input.adjustmentData, data.formatIdentifier == Self.formatIdentifier else { return nil }
        return data.data
    }

    /// Whether adjustment data is Easel's, carrying layers that can be read
    /// back over the original photo.
    static func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == formatIdentifier
            && adjustmentData.formatVersion == formatVersion
            && PhotoEditPayload.isAvailable(adjustmentData.data)
    }

    /// Reads the input. When Photos handed over the original because Easel
    /// can resume its own edit, the layers are rebuilt on top of it;
    /// otherwise the photo, as currently edited, is the single layer.
    @concurrent
    static func load(_ input: PHContentEditingInput) async throws -> PhotoEditingSession {
        guard let url = input.fullSizeImageURL else { throw ImageCodec.Failure.unreadable }
        let image = try ImageCodec.decode(contentsOf: url)
        let original = LayerImage(image)
        if let data = input.adjustmentData, canHandle(data),
           let archive = PhotoEditPayload.decode(data.data),
           let composition = try? CompositionArchive.composition(from: archive, original: original) {
            return PhotoEditingSession(input: input, original: original, composition: composition, isResumed: true)
        }
        let name = String(localized: "Layer.DefaultName.Photo")
        let composition = Composition(
            size: original.size, layers: [Layer(name: name, image: original, canvasSize: original.size)]
        )
        return PhotoEditingSession(input: input, original: original, composition: composition, isResumed: false)
    }

    /// The finished edit: the flattened picture at the place Photos asked for,
    /// with the photo's own metadata, and the layers as adjustment data.
    @concurrent
    func output(for composition: Composition) async throws -> PHContentEditingOutput {
        let output = PHContentEditingOutput(contentEditingInput: input)
        let type = output.defaultRenderedContentType ?? .jpeg
        let url = try output.renderedContentURL(for: type)
        let flattened = CompositionRenderer.render(composition)
        let metadata = input.fullSizeImageURL.flatMap(ImageCodec.metadata(contentsOf:))
        try ImageCodec.encode(flattened, as: type, metadata: metadata).write(to: url, options: .atomic)

        // Without its layers the edit still saves; it just opens flattened.
        let archive = try? CompositionArchive.data(for: composition, original: original)
        let data = archive.flatMap { try? PhotoEditPayload.encode($0) } ?? Data()
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.formatIdentifier, formatVersion: Self.formatVersion, data: data
        )
        return output
    }
}
