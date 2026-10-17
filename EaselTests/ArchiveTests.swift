import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Saving and opening")
struct ArchiveTests {
    private func sample() -> Composition {
        let size = CGSize(width: 8, height: 4)
        var text = Layer(
            name: "Title", image: LayerImage(TextRenderer.render(TextContent(string: "Hi", fontSize: 12, color: .black))),
            text: TextContent(string: "Hi", fontSize: 12, color: .black),
            transform: LayerTransform(position: CGPoint(x: 3, y: 2), scaleX: -1, scaleY: 1.5, rotation: 0.25)
        )
        text.opacity = 0.4
        text.blendMode = .screen
        text.isLocked = true
        var hidden = Layer(name: "Hidden", image: LayerImage(TestImages.halves()), canvasSize: size)
        hidden.isVisible = false
        return Composition(size: size, layers: [
            Layer(name: "Background", image: LayerImage(TestImages.halves()), canvasSize: size), text, hidden,
        ])
    }

    @Test func packageKeepsEveryLayerAndItsSettings() throws {
        let original = sample()
        let wrapper = try CompositionArchive.fileWrapper(for: original)
        #expect(wrapper.fileWrappers?["Manifest.json"] != nil)
        #expect(wrapper.fileWrappers?["QuickLook"]?.fileWrappers?["Thumbnail.png"] != nil)

        // Through the disk, as a document would go.
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try wrapper.write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CompositionArchive.composition(from: FileWrapper(url: url))

        #expect(read.size == original.size)
        #expect(read.layers.map(\.id) == original.layers.map(\.id))
        #expect(read.layers.map(\.name) == original.layers.map(\.name))
        #expect(read.layers[1].text == original.layers[1].text)
        #expect(read.layers[1].transform == original.layers[1].transform)
        #expect(read.layers[1].opacity == 0.4)
        #expect(read.layers[1].blendMode == .screen)
        #expect(read.layers[1].isLocked)
        #expect(!read.layers[2].isVisible)
        #expect(TestImages.isRed(read.layers[0].image.cgImage, x: 1, y: 1))
        #expect(TestImages.isBlue(read.layers[0].image.cgImage, x: 6, y: 1))
    }

    @Test func layersSharingPixelsAreWrittenOnce() throws {
        var composition = sample()
        composition.duplicate(composition.layers[0].id)
        let wrapper = try CompositionArchive.fileWrapper(for: composition)
        let files = wrapper.fileWrappers?["Layers"]?.fileWrappers ?? [:]
        #expect(files.count == composition.layers.count - 1)
    }

    @Test func photoEditBlobLeavesTheOriginalOut() throws {
        let photo = LayerImage(TestImages.halves())
        let size = photo.size
        let composition = Composition(size: size, layers: [
            Layer(name: "Photo", image: photo, canvasSize: size),
            Layer(name: "Ink", image: LayerImage(TestImages.solid(.black, width: 8, height: 4)), canvasSize: size),
        ])
        let withOriginal = try CompositionArchive.data(for: composition, original: photo)
        let withoutOriginal = try CompositionArchive.data(for: composition, original: nil)
        #expect(withOriginal.count < withoutOriginal.count)

        // Read back over the original the library hands over again.
        let original = LayerImage(TestImages.halves())
        let read = try CompositionArchive.composition(from: withOriginal, original: original)
        #expect(read.layers.count == 2)
        #expect(read.layers[0].image === original)
        #expect(read.layers[1].name == "Ink")
    }

    @Test func photoEditBlobNeedsItsOriginal() throws {
        let photo = LayerImage(TestImages.halves())
        let composition = Composition(size: photo.size, layers: [Layer(name: "Photo", image: photo, canvasSize: photo.size)])
        let data = try CompositionArchive.data(for: composition, original: photo)
        #expect(throws: (any Error).self) { try CompositionArchive.composition(from: data, original: nil) }
    }

    @Test func picturesDecodeUpright() throws {
        let data = try ImageCodec.encode(TestImages.halves(), as: .png)
        let image = try ImageCodec.decode(data)
        #expect(image.width == 8 && image.height == 4)
        #expect(TestImages.isRed(image, x: 1, y: 1))
    }

    @Test func opaqueFormatsGetAWhiteBackground() throws {
        let data = try ImageCodec.encode(TestImages.solid(.clear), as: .jpeg)
        let image = try ImageCodec.decode(data)
        #expect(TestImages.pixel(image, x: 2, y: 2).red > 240)
    }
}

@Suite("Photo edits")
struct PhotoEditPayloadTests {
    @Test func smallEditsTravelInline() throws {
        let archive = Data(repeating: 7, count: 1000)
        let data = try PhotoEditPayload.encode(archive)
        #expect(data.count < 2000)
        #expect(PhotoEditPayload.isAvailable(data))
        #expect(PhotoEditPayload.decode(data) == archive)
    }

    @Test func largeEditsStayUnderWhatPhotosAccepts() throws {
        let archive = Data(repeating: 7, count: PhotoEditPayload.inlineLimit + 1)
        let data = try PhotoEditPayload.encode(archive)
        // Photos raises an exception for adjustment data over 2 MiB.
        #expect(data.count < 2 * 1024 * 1024)
        #expect(PhotoEditPayload.decode(data) == archive)
    }

    @Test func somethingElsesDataIsNotOurs() {
        #expect(!PhotoEditPayload.isAvailable(Data("not ours".utf8)))
        #expect(PhotoEditPayload.decode(Data()) == nil)
    }
}

@Suite("Photo edit clean-up")
struct PhotoEditCleanupTests {
    @Test func discardingRemovesTheKeptCopy() throws {
        let archive = Data(repeating: 9, count: PhotoEditPayload.inlineLimit + 10)
        let data = try PhotoEditPayload.encode(archive)
        #expect(PhotoEditPayload.isAvailable(data))
        PhotoEditPayload.discard(data)
        #expect(!PhotoEditPayload.isAvailable(data))
    }

    @Test func discardingInlineDataIsHarmless() throws {
        let data = try PhotoEditPayload.encode(Data([1, 2, 3]))
        PhotoEditPayload.discard(data)
        PhotoEditPayload.discard(nil)
        #expect(PhotoEditPayload.decode(data) == Data([1, 2, 3]))
    }
}
