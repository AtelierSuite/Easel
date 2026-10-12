import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Smart objects")
struct SmartObjectTests {
    private let size = CGSize(width: 40, height: 20)

    private func picture() -> Composition {
        Composition(size: size, layers: [
            Layer(name: "Paper", image: LayerImage(TestImages.solid(.white, width: 40, height: 20)), canvasSize: size),
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 10, height: 10)),
                  transform: LayerTransform(position: CGPoint(x: 5, y: 5))),
        ])
    }

    @Test func convertingKeepsTheLayerWholeInside() throws {
        var composition = picture()
        let converted = composition.convertToSmartObject([composition.layers[1].id])
        let id = try #require(converted)
        let layer = try #require(composition[id])
        #expect(layer.isSmartObject)
        #expect(layer.smartObject?.contents.layers.map(\.name) == ["Red"])
        #expect(composition.layers.count == 2)
        // It looks just as before.
        #expect(TestImages.isRed(CompositionRenderer.render(composition), x: 5, y: 5))
    }

    @Test func newContentsAreDrawnOutWhereTheLayerSits() throws {
        var composition = picture()
        let converted = composition.convertToSmartObject([composition.layers[1].id])
        let id = try #require(converted)
        var contents = try #require(composition[id]?.smartObject?.contents)
        contents.layers[0].transform.position = CGPoint(x: 30, y: 10)
        composition[id]?.setSmartObjectContents(contents)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(image, x: 30, y: 10))
        #expect(!TestImages.isRed(image, x: 5, y: 5))
    }

    @Test func smartObjectsAreSavedWithTheirContents() throws {
        var composition = picture()
        let converted = composition.convertToSmartObject([composition.layers[1].id])
        let id = try #require(converted)
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read[id]?.smartObject?.contents.layers.map(\.name) == ["Red"])
    }

    @Test func rasterizingLetsGoOfTheContents() throws {
        var composition = picture()
        let converted = composition.convertToSmartObject([composition.layers[1].id])
        let id = try #require(converted)
        composition.rasterize(id)
        #expect(composition[id]?.isSmartObject == false)
    }

    @MainActor @Test func paintingOnASmartObjectIsRefused() {
        let state = EditorState()
        state.attach(to: picture()) { _ in }
        state.activeLayerID = state.composition.layers[1].id
        state.convertToSmartObject()
        state.tool = .brush
        #expect(state.paintingBlocker() == String(localized: "Error.SmartObject"))
    }

    @MainActor @Test func aGroupBecomesOneSmartObject() {
        let state = EditorState()
        var composition = picture()
        let group = LayerGroup(name: "Folder")
        composition.groups = [group]
        composition.layers[0].groupID = group.id
        composition.layers[1].groupID = group.id
        state.attach(to: composition) { _ in }
        state.activeGroupID = group.id
        state.convertToSmartObject()
        #expect(state.composition.layers.count == 1)
        #expect(state.composition.layers[0].smartObject?.contents.layers.count == 2)
        #expect(state.composition.groups.isEmpty)
    }
}
