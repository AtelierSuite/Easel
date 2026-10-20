import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Layer comps")
struct LayerCompTests {
    private let size = CGSize(width: 40, height: 20)

    private func picture() -> Composition {
        Composition(size: size, layers: [
            Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 40, height: 20)), canvasSize: size),
            Layer(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 10, height: 10)),
                  transform: LayerTransform(position: CGPoint(x: 5, y: 5))),
        ])
    }

    @Test func aCompBringsBackVisibilityAndPlace() {
        var composition = picture()
        let comp = composition.layerComp(named: "Start")
        composition.layers[1].isVisible = false
        composition.layers[1].transform.position = CGPoint(x: 30, y: 10)
        composition.layers[0].opacity = 0.5
        let back = composition.applying(comp)
        #expect(back.layers[1].isVisible)
        #expect(back.layers[1].transform.position == CGPoint(x: 5, y: 5))
        #expect(back.layers[0].opacity == 1)
    }

    @Test func layersAddedSinceAreLeftAlone() {
        var composition = picture()
        let comp = composition.layerComp(named: "Start")
        var extra = composition.emptyLayer()
        extra.opacity = 0.3
        composition.layers.append(extra)
        #expect(composition.applying(comp).layers[2].opacity == 0.3)
    }

    @Test func compsAreSaved() throws {
        var composition = picture()
        composition.layerComps = [composition.layerComp(named: "One")]
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layerComps == composition.layerComps)
    }

    @Test func eachCompExportsAsItsOwnPicture() throws {
        var composition = picture()
        composition.layerComps.append(composition.layerComp(named: "With Blue"))
        composition.layers[1].isVisible = false
        composition.layerComps.append(composition.layerComp(named: "Without Blue"))
        let files = try EditorState.exportLayerComps(of: composition)
        #expect(files.map(\.lastPathComponent) == ["With Blue.png", "Without Blue.png"])
        let with = try ImageCodec.decode(try Data(contentsOf: files[0]))
        let without = try ImageCodec.decode(try Data(contentsOf: files[1]))
        #expect(TestImages.isBlue(with, x: 5, y: 5))
        #expect(TestImages.isRed(without, x: 5, y: 5))
    }

    @MainActor @Test func theEditorSavesAndAppliesComps() {
        let state = EditorState()
        state.attach(to: picture()) { _ in }
        state.addLayerComp()
        state.setVisibility(false, of: state.composition.layers[1].id)
        state.applyLayerComp(state.composition.layerComps[0].id)
        #expect(state.composition.layers[1].isVisible)
        #expect(state.composition.layerComps[0].name == String(localized: "Comps.DefaultName") + " 1")
    }
}

@Suite("Layer comps and painting")
struct LayerCompPaintingTests {
    @Test func aLayerPaintedOntoSinceKeepsItsNewPlace() {
        let size = CGSize(width: 40, height: 20)
        var composition = Composition(size: size, layers: [
            Layer(name: "Small", image: LayerImage(TestImages.solid(.black, width: 10, height: 10)),
                  transform: LayerTransform(position: CGPoint(x: 5, y: 5))),
        ])
        let comp = composition.layerComp(named: "Before")
        composition.layers[0] = composition.layers[0].aligned(in: size)
        #expect(composition.applying(comp).layers[0].transform == composition.layers[0].transform)
    }
}
