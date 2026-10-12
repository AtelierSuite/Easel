import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Artboards")
struct ArtboardTests {
    private let size = CGSize(width: 40, height: 20)

    /// Red on the left half, blue on the right.
    private func picture() -> Composition {
        Composition(size: size, layers: [Layer(name: "Halves", image: LayerImage(TestImages.halves(width: 40, height: 20)), canvasSize: size)])
    }

    @Test func anArtboardRendersItsPartOfTheCanvas() {
        var composition = picture()
        composition.artboards = [Artboard(name: "Right", rect: CGRect(x: 20, y: 0, width: 20, height: 20))]
        let image = composition.render(composition.artboards[0])
        #expect(image.width == 20 && image.height == 20)
        #expect(TestImages.isBlue(image, x: 2, y: 2))
    }

    @Test func artboardsFollowTheCanvasWhenItIsCropped() {
        var composition = picture()
        composition.artboards = [Artboard(name: "Right", rect: CGRect(x: 20, y: 0, width: 20, height: 20))]
        composition.crop(to: CGRect(x: 10, y: 0, width: 30, height: 20))
        #expect(composition.artboards[0].rect == CGRect(x: 10, y: 0, width: 20, height: 20))
        composition.crop(to: CGRect(x: 0, y: 0, width: 5, height: 20))
        #expect(composition.artboards.isEmpty)
    }

    @Test func artboardsAreSavedAndExported() throws {
        var composition = picture()
        composition.artboards = [Artboard(name: "Left", rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                 Artboard(name: "Right", rect: CGRect(x: 20, y: 0, width: 20, height: 20))]
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.artboards == composition.artboards)
        let files = try EditorState.exportArtboards(of: composition)
        #expect(files.map(\.lastPathComponent) == ["Left.png", "Right.png"])
        #expect(TestImages.isRed(try ImageCodec.decode(try Data(contentsOf: files[0])), x: 2, y: 2))
    }

    @MainActor @Test func aNewArtboardCoversTheSelection() {
        let state = EditorState()
        state.attach(to: picture()) { _ in }
        state.selection = Selection(shape: .rectangle(CGRect(x: 5, y: 5, width: 10, height: 10)))
        state.addArtboard()
        #expect(state.composition.artboards.first?.rect == CGRect(x: 5, y: 5, width: 10, height: 10))
    }
}
