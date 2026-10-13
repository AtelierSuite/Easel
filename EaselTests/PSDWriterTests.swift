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
