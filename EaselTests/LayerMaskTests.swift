import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Layer masks")
struct LayerMaskTests {
    private let size = CGSize(width: 8, height: 4)

    /// A mask showing only the left half of an 8 by 4 layer.
    private func leftHalfMask() -> LayerMask {
        LayerMask(image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }))
    }

    private func masked() -> Layer {
        var layer = Layer(name: "Halves", image: LayerImage(TestImages.halves()), canvasSize: size)
        layer.mask = leftHalfMask()
        return layer
    }

    @Test func aMaskHidesWithoutChangingPixels() {
        let layer = masked()
        let image = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        #expect(TestImages.isRed(image, x: 1, y: 1))
        #expect(TestImages.isClear(image, x: 6, y: 1))
        #expect(TestImages.isBlue(layer.image.cgImage, x: 6, y: 1))
    }

    @Test func aDisabledMaskShowsEverything() {
        var layer = masked()
        layer.mask?.isEnabled = false
        let image = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        #expect(TestImages.isBlue(image, x: 6, y: 1))
    }

    @Test func invertingSwapsWhatShows() {
        var layer = masked()
        layer.mask = layer.mask?.inverted()
        let image = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        #expect(TestImages.isClear(image, x: 1, y: 1))
        #expect(TestImages.isBlue(image, x: 6, y: 1))
    }

    @Test func masksWorkWithFilters() {
        var layer = masked()
        layer.filters = [LayerFilter(kind: .blackAndWhite)]
        let image = layer.renderedImage
        let left = TestImages.pixel(image, x: 1, y: 1)
        #expect(abs(left.red - left.green) < 12)
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    @Test func applyingPaintsTheMaskIn() {
        var composition = Composition(size: size, layers: [masked()])
        composition.rasterize(composition.layers[0].id)
        #expect(composition.layers[0].mask == nil)
        #expect(TestImages.isClear(composition.layers[0].image.cgImage, x: 6, y: 1))
    }

    @Test func aligningCarriesTheMaskAndShowsTheNewEdges() {
        var layer = masked()
        layer.transform.position.x += 2
        let aligned = layer.aligned(in: CGSize(width: 12, height: 4))
        let mask = aligned.mask!.image.cgImage
        #expect(mask.width == 12)
        // Off the layer's old edges, everything shows.
        #expect(TestImages.pixel(mask, x: 0, y: 1).alpha > 250)
        // Its own right half stays hidden.
        #expect(TestImages.pixel(mask, x: 9, y: 1).alpha == 0)
    }

    @Test func masksAreSaved() throws {
        var layer = masked()
        layer.mask?.isEnabled = false
        let composition = Composition(size: size, layers: [layer])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try CompositionArchive.fileWrapper(for: composition).write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CompositionArchive.composition(from: FileWrapper(url: url))
        let mask = try #require(read.layers[0].mask)
        #expect(!mask.isEnabled)
        #expect(TestImages.pixel(mask.image.cgImage, x: 6, y: 1).alpha == 0)
    }
}

@MainActor
@Suite("Mask commands")
struct MaskCommandTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 20, height: 20))
        composition.layers[0].image = LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 20, height: 20))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        return (state, { published })
    }

    @Test func aMaskFromASelectionShowsOnlyThatPart() {
        let (state, published) = host()
        state.selection = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 20)))
        state.addMask()
        #expect(state.isEditingMask)
        let image = CompositionRenderer.render(published())
        #expect(TestImages.isRed(image, x: 5, y: 5))
        #expect(TestImages.isClear(image, x: 15, y: 5))
    }

    @Test func theBrushHidesThroughTheMask() async throws {
        let (state, published) = host()
        state.addMask()
        state.tool = .brush
        state.brush.size = 6
        state.toolBegan(at: CGPoint(x: 2, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 18, y: 10))])
        state.toolEnded(isTap: false, at: CGPoint(x: 18, y: 10))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let layer = published().layers[0]
        // The pixels are still red; the mask hides them along the stroke.
        #expect(TestImages.isRed(layer.image.cgImage, x: 10, y: 10))
        #expect(TestImages.isClear(CompositionRenderer.render(published()), x: 10, y: 10))
        #expect(TestImages.isRed(CompositionRenderer.render(published()), x: 10, y: 2))
    }

    @Test func aFoundSubjectReplacesTheMaskOfAMovedLayer() throws {
        let (state, published) = host()
        state.addMask()
        state.updateActiveLayer { $0.transform.position.x += 5 }
        // The subject: the canvas's right half.
        var bytes = [UInt8](repeating: 0, count: 20 * 20)
        for y in 0..<20 { for x in 10..<20 { bytes[y * 20 + x] = 255 } }
        let subject = try #require(SelectionMask(bytes: bytes, width: 20, height: 20))
        state.mask(state.activeLayerID!, revealing: Selection(shape: .mask(subject)))
        #expect(!state.isEditingMask)
        let image = CompositionRenderer.render(published())
        #expect(TestImages.isRed(image, x: 15, y: 10))
        #expect(TestImages.isClear(image, x: 7, y: 10))
    }

    @Test func removingTheBackgroundEndsWithAMaskOrAReason() async throws {
        let (state, published) = host()
        state.removeBackground()
        for _ in 0..<200 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        // Vision's model does not run in Simulator, which must say so
        // rather than fail quietly.
        #expect(published().layers[0].mask != nil || state.errorMessage != nil)
    }

    @Test func otherToolsCannotPaintAMask() {
        let (state, _) = host()
        state.addMask()
        state.tool = .censor
        state.censorKind = .smudge
        #expect(state.paintingBlocker() != nil)
        state.tool = .eraser
        #expect(state.paintingBlocker() == nil)
    }

    @Test func choosingAnotherLayerStopsMaskPainting() {
        let (state, _) = host()
        state.addMask()
        state.addEmptyLayer()
        #expect(!state.isEditingMask)
    }
}
