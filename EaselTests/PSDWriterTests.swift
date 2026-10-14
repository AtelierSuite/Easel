import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Easel

@Suite("Saving Photoshop documents")
struct PSDWriterTests {
    private let size = CGSize(width: 20, height: 10)

    private func sample() -> Composition {
        let group = LayerGroup(name: "Folder", opacity: 0.5)
        var back = Layer(name: "Back", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 20, height: 10)), canvasSize: size)
        back.blendMode = .normal
        var blue = Layer(
            name: "青い", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 6, height: 4)),
            transform: LayerTransform(position: CGPoint(x: 13, y: 5))
        )
        blue.opacity = 0.6
        blue.blendMode = .screen
        blue.groupID = group.id
        blue.mask = LayerMask(image: LayerImage(Bitmap.render(size: CGSize(width: 6, height: 4)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 4))
        }))
        var hidden = Layer(name: "Hidden", image: LayerImage(TestImages.solid(.black, width: 2, height: 2)),
                           transform: LayerTransform(position: CGPoint(x: 2, y: 2)))
        hidden.isVisible = false
        return Composition(size: size, layers: [back, blue, hidden], groups: [group])
    }

    @Test func layersSurviveTheRoundTrip() throws {
        let read = try PSDReader.composition(from: try PSDWriter.data(for: sample()))
        #expect(read.size == size)
        #expect(read.layers.map(\.name) == ["Back", "青い", "Hidden"])
        let blue = read.layers[1]
        #expect(blue.image.size == CGSize(width: 6, height: 4))
        #expect(blue.transform.position == CGPoint(x: 13, y: 5))
        #expect(abs(blue.opacity - 0.6) < 0.01)
        #expect(blue.blendMode == .screen)
        #expect(TestImages.isBlue(blue.image.cgImage, x: 4, y: 2))
        let mask = try #require(blue.mask)
        #expect(TestImages.pixel(mask.image.cgImage, x: 1, y: 1).alpha > 250)
        #expect(TestImages.pixel(mask.image.cgImage, x: 5, y: 1).alpha == 0)
        #expect(!read.layers[2].isVisible)
        #expect(read.groups.map(\.name) == ["Folder"])
        #expect(abs(read.groups[0].opacity - 0.5) < 0.01)
        #expect(blue.groupID == read.groups[0].id)
        #expect(read.layers[0].groupID == nil)
    }

    /// A layer only moved keeps its pixels past the canvas's edges, and
    /// its mask with them.
    @Test func movedLayersKeepPixelsOffTheCanvas() throws {
        var layer = Layer(name: "Off", image: LayerImage(TestImages.halves(width: 8, height: 4)),
                          transform: LayerTransform(position: CGPoint(x: 1, y: -1)))
        layer.mask = LayerMask(image: LayerImage(Bitmap.render(size: CGSize(width: 8, height: 4)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }))
        let read = try PSDReader.composition(from: try PSDWriter.data(for: Composition(size: size, layers: [layer])))
        let off = try #require(read.layers.first)
        #expect(off.image.size == CGSize(width: 8, height: 4))
        #expect(off.transform.position == CGPoint(x: 1, y: -1))
        #expect(TestImages.isRed(off.image.cgImage, x: 0, y: 0))
        #expect(TestImages.isBlue(off.image.cgImage, x: 7, y: 3))
        let mask = try #require(off.mask)
        #expect(TestImages.pixel(mask.image.cgImage, x: 0, y: 0).alpha > 250)
        #expect(TestImages.pixel(mask.image.cgImage, x: 6, y: 3).alpha == 0)
    }

    @Test func documentSettingsSurviveTheRoundTrip() throws {
        var composition = sample()
        composition.resolution = 300
        composition.guides = [Guide(axis: .vertical, position: 4.5), Guide(axis: .horizontal, position: 7)]
        composition.layers[0].isLocked = true
        composition.groups[0].isLocked = true
        composition.artboards = [Artboard(name: "Board", rect: CGRect(x: 2, y: 1, width: 12, height: 8), groupID: composition.groups[0].id)]
        // A comp with the blue layer moved, faded, multiplied and hidden.
        var comp = composition.layerComp(named: "Moved")
        let blueID = composition.layers[1].id
        comp.states[blueID]?.transform.position.x += 3
        comp.states[blueID]?.opacity = 0.3
        comp.states[blueID]?.blendMode = .multiply
        comp.states[blueID]?.isVisible = false
        composition.layerComps = [comp, composition.layerComp(named: "As is")]

        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        #expect(read.resolution == 300)
        #expect(read.guides.map(\.axis) == [.vertical, .horizontal])
        #expect(read.guides.map(\.position) == [4.5, 7])
        #expect(read.layers.map(\.isLocked) == [true, false, false])
        #expect(read.groups.map(\.isLocked) == [true])
        #expect(read.artboards.map(\.name) == ["Folder"])
        #expect(read.artboards.first?.rect == CGRect(x: 2, y: 1, width: 12, height: 8))
        #expect(read.artboards.first?.groupID == read.groups.first?.id)
        #expect(read.layerComps.map(\.name) == ["Moved", "As is"])
        let blue = read.layers[1]
        let moved = try #require(read.layerComps[0].states[blue.id])
        #expect(moved.transform.position == CGPoint(x: blue.transform.position.x + 3, y: blue.transform.position.y))
        #expect(abs(moved.opacity - 0.3) < 0.01)
        #expect(moved.blendMode == .multiply)
        #expect(!moved.isVisible)
        let asIs = try #require(read.layerComps[1].states[blue.id])
        #expect(asIs.transform.position == blue.transform.position && asIs.isVisible && asIs.blendMode == .screen)
    }

    @Test func whatEaselDoesNotUseGoesBack() throws {
        var composition = sample()
        var blue = composition.layers[1]
        let label = PhotoshopExtras.Block(key: "lclr", data: Data([0, 2, 0, 0, 0, 0, 0, 0]))
        let text = PhotoshopExtras.Block(key: "TySh", data: Data([1, 2, 3, 4]))
        blue.photoshop = PhotoshopExtras(
            blocks: [label, text], blendingRanges: Data([0, 0, 255, 255, 0, 0, 255, 255]), maskParameters: Data([0x01, 128]),
            source: .init(image: blue.image.id, mask: blue.mask?.image.id, transform: blue.transform, filters: blue.filters)
        )
        composition.layers[1] = blue
        composition.groups[0].photoshop = PhotoshopExtras(blocks: [label])
        composition.photoshop = PhotoshopDocumentExtras(
            resources: [.init(id: 1037, name: [], data: Data([0, 0, 0, 30]))],
            blocks: [.init(key: "Txt2", data: Data([9, 9, 9, 9]))]
        )
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        let extras = try #require(read.layers[1].photoshop)
        #expect(extras.blocks == [label, text])
        #expect(extras.blendingRanges == Data([0, 0, 255, 255, 0, 0, 255, 255]))
        #expect(extras.maskParameters == Data([0x01, 128]))
        #expect(read.layers[1].mask != nil)
        #expect(read.groups[0].photoshop?.blocks == [label])
        #expect(read.photoshop?.resources.contains { $0.id == 1037 && $0.data == Data([0, 0, 0, 30]) } == true)
        #expect(read.photoshop?.blocks.contains(.init(key: "Txt2", data: Data([9, 9, 9, 9]))) == true)

        // Once the layer has moved, its text no longer says what it shows.
        var moved = read
        moved.layers[1].transform.position.x += 1
        let again = try PSDReader.composition(from: try PSDWriter.data(for: moved))
        #expect(again.layers[1].photoshop?.blocks == [label])
    }

    @Test func photoshopsOwnRecordsGoBackWhileUnchanged() throws {
        // A Color Lookup, which Easel cannot draw, and styles Photoshop
        // kept as `lmfx`.
        var lookup = Layer(name: "Lookup", image: LayerImage(Bitmap.solid(size: size, color: .clear)), canvasSize: size)
        lookup.adjustment = LayerFilter(kind: .curves)
        lookup.photoshop = PhotoshopExtras()
        lookup.photoshop?.adjustment = .init(blocks: [.init(key: "clrL", data: Data([0, 3, 0, 0]))], value: lookup.adjustment!,
                                             transform: lookup.transform)
        var styled = sample().layers[1]
        styled.mask = nil
        var shadow = LayerEffect(kind: .dropShadow)
        shadow.distance = 4
        styled.effects = [shadow]
        let block = try #require(PSDEffects.block(for: styled.effects) { _ in nil })
        styled.photoshop = PhotoshopExtras()
        styled.photoshop?.effects = .init(blocks: [.init(key: "lmfx", data: Data(block))], value: styled.effects, transform: styled.transform)

        let read = try PSDReader.composition(from: try PSDWriter.data(for: Composition(size: size, layers: [lookup, styled])))
        #expect(read.layers.count == 2)
        #expect(read.layers[0].photoshop?.adjustment?.blocks == [.init(key: "clrL", data: Data([0, 3, 0, 0]))])
        #expect(read.layers[1].photoshop?.effects?.blocks.map(\.key) == ["lmfx"])
        #expect(read.layers[1].effects.map(\.kind) == [.dropShadow])

        // Changed in Easel, they go as Easel's own.
        var changed = read
        changed.layers[0].adjustment?.curve = [0, 0.3, 0.5, 0.7, 1]
        changed.layers[1].effects[0].distance = 8
        let again = try PSDReader.composition(from: try PSDWriter.data(for: changed))
        #expect(again.layers[0].photoshop?.adjustment?.blocks.map(\.key) == ["curv"])
        #expect(again.layers[1].photoshop?.effects?.blocks.map(\.key) == ["lfx2"])
    }

    @Test func coloursGoBackToTheFilesProfile() throws {
        var composition = sample()
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        composition.photoshop = PhotoshopDocumentExtras(colorProfile: srgb)
        let data = try PSDWriter.data(for: composition)
        let read = try PSDReader.composition(from: data)
        #expect(read.photoshop?.colorProfile == srgb)
        // Red in sRGB is red again once read back.
        #expect(TestImages.isRed(read.layers[0].image.cgImage, x: 2, y: 2))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let merged = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(merged.colorSpace?.name == CGColorSpace.sRGB || merged.colorSpace.flatMap { $0.copyICCData() as Data? } == srgb)
    }

    /// Easel's own adjustments go as the pixels they make of what is beneath.
    @Test func adjustmentsPhotoshopLacksGoAsPixels() throws {
        var composition = Composition(size: size, layers: [
            Layer(name: "Back", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 20, height: 10)), canvasSize: size),
        ])
        var adjustment = composition.adjustmentLayer(.sepia)
        adjustment.adjustment?.amount = 1
        composition.layers.append(adjustment)
        #expect(PSDAdjustments.blocks(for: adjustment.adjustment!) == nil)
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        #expect(read.layers.count == 2)
        #expect(read.layers[1].adjustment == nil)
        let written = TestImages.pixel(read.layers[1].image.cgImage, x: 5, y: 5)
        let expected = TestImages.pixel(CompositionRenderer.render(composition), x: 5, y: 5)
        #expect(written.alpha > 250 && abs(written.red - expected.red) < 4 && abs(written.green - expected.green) < 4)
    }

    @Test func otherAppsSeeTheFlattenedPicture() throws {
        let data = try PSDWriter.data(for: sample())
        let image = try ImageCodec.decode(data)
        #expect(image.width == 20 && image.height == 10)
        #expect(TestImages.isRed(image, x: 2, y: 8))
    }

    @Test func packBitsRoundTrips() {
        let rows: [[UInt8]] = [[], [1], [1, 1, 1, 1], [1, 2, 3, 3, 3, 3, 4], Array(repeating: 7, count: 300), (0..<300).map { UInt8($0 % 251) }]
        for row in rows {
            #expect(PSDReader.unpackBits(PSDWriter.packBits(row), expected: row.count) == row)
        }
    }
}
