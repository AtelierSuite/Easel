import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Photoshop smart objects")
struct PSDSmartObjectTests {
    private let size = CGSize(width: 80, height: 60)

    private func smartLayer(transform: LayerTransform) -> Layer {
        let red = Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 10, height: 10)),
                        transform: LayerTransform(position: CGPoint(x: 5, y: 5)))
        let blue = Layer(name: "Blue", image: LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 10, height: 10)),
                         transform: LayerTransform(position: CGPoint(x: 15, y: 15)))
        var layer = Layer(name: "Smart", image: LayerImage(Bitmap.solid(size: CGSize(width: 20, height: 20), color: .clear)), transform: transform)
        layer.setSmartObjectContents(Composition(size: CGSize(width: 20, height: 20), layers: [red, blue]))
        return layer
    }

    private func roundTrip(_ layers: [Layer]) throws -> Composition {
        try PSDReader.composition(from: try PSDWriter.data(for: Composition(size: size, layers: layers)))
    }

    @Test func contentsComeBackAsLayers() throws {
        let read = try #require(try roundTrip([smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))]).layers.first)
        let contents = try #require(read.smartObject?.contents)
        #expect(contents.size == CGSize(width: 20, height: 20))
        #expect(contents.layers.map(\.name) == ["Red", "Blue"])
        #expect(read.transform.position == CGPoint(x: 40, y: 30))
    }

    @Test func movedScaledAndTurnedObjectsKeepTheirPlace() throws {
        let transform = LayerTransform(position: CGPoint(x: 37, y: 28), scaleX: 1.5, scaleY: -2, rotation: Double.pi / 6)
        let read = try #require(try roundTrip([smartLayer(transform: transform)]).layers.first)
        #expect(read.isSmartObject)
        #expect(abs(read.transform.position.x - 37) < 0.001 && abs(read.transform.position.y - 28) < 0.001)
        #expect(abs(read.transform.scaleX - 1.5) < 0.001)
        #expect(abs(read.transform.scaleY + 2) < 0.001)
        #expect(abs(read.transform.rotation - Double.pi / 6) < 0.001)
    }

    @Test func masksStayWhereTheyWere() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 2))
        // Hide the left half of the contents.
        layer.mask = LayerMask(image: LayerImage(Bitmap.render(size: CGSize(width: 20, height: 20)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 20))
        }))
        let before = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        let read = try roundTrip([layer])
        #expect(read.layers.first?.isSmartObject == true)
        let after = CompositionRenderer.render(read)
        for (x, y) in [(25, 25), (35, 25), (45, 35), (55, 35)] {
            #expect(abs(Int(TestImages.pixel(before, x: x, y: y).alpha) - Int(TestImages.pixel(after, x: x, y: y).alpha)) < 8)
        }
    }

    @Test func smartFiltersComeBackInOrder() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 2))
        var blur = LayerFilter(kind: .gaussianBlur)
        blur.amount = 0.2
        var motion = LayerFilter(kind: .motionBlur)
        motion.amount = 0.1
        motion.angle = 30
        motion.isEnabled = false
        var curves = LayerFilter(kind: .curves)
        curves.curve = [0, 0.4, 0.7, 0.9, 1]
        layer.filters = [blur, motion, curves]
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        #expect(read.filters.map(\.kind) == [.gaussianBlur, .motionBlur, .curves])
        #expect(abs(read.filters[0].amount - 0.2) < 0.001)
        #expect(abs(read.filters[1].amount - 0.1) < 0.01)
        #expect(abs(read.filters[1].angle - 30) < 0.5)
        #expect(read.filters[1].isEnabled == false)
        let curve = try #require(read.filters[2].curve)
        #expect(zip(curve, [0, 0.4, 0.7, 0.9, 1]).allSatisfy { abs($0 - $1) < 0.01 })
    }

    @Test func filtersPhotoshopLacksLeaveThePixels() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [LayerFilter(kind: .sepia)]
        let read = try #require(try roundTrip([layer]).layers.first)
        // Drawn as it looked, sepia and all, rather than losing the filter.
        #expect(!read.isSmartObject)
        #expect(read.filters.isEmpty)
        let pixel = TestImages.pixel(CompositionRenderer.render(Composition(size: size, layers: [read])), x: 35, y: 25)
        #expect(pixel.green > 40)
    }

    @Test func nestedSmartObjectsComeBack() throws {
        var outer = Layer(name: "Outer", image: LayerImage(Bitmap.solid(size: size, color: .clear)), canvasSize: size)
        outer.setSmartObjectContents(Composition(size: size, layers: [smartLayer(transform: LayerTransform(position: CGPoint(x: 20, y: 20)))]))
        let read = try #require(try roundTrip([outer]).layers.first)
        #expect(read.smartObject?.contents.layers.first?.smartObject?.contents.layers.count == 2)
    }

    @Test func perspectiveCornersAreNotAMoveAndScale() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 2), CGPoint(x: 12, y: 12), CGPoint(x: 0, y: 10)]
        #expect(PSDSmartObjects.transform(corners: corners, size: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func objectsInPerspectiveComeBackBent() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        let corners = [CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 18), CGPoint(x: 64, y: 50), CGPoint(x: 16, y: 44)]
        layer.setSmartObjectWarp(.perspective(corners))
        let before = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        guard case .perspective(let back) = try #require(read.canvasWarp) else { Issue.record("not in perspective"); return }
        for (a, b) in zip(back, corners) { #expect(hypot(a.x - b.x, a.y - b.y) < 0.01) }
        let after = CompositionRenderer.render(Composition(size: size, layers: [read]))
        for (x, y) in [(25, 20), (55, 25), (40, 40), (60, 45)] {
            let p = TestImages.pixel(before, x: x, y: y), q = TestImages.pixel(after, x: x, y: y)
            #expect(abs(Int(p.red) - Int(q.red)) < 10 && abs(Int(p.blue) - Int(q.blue)) < 10 && abs(Int(p.alpha) - Int(q.alpha)) < 10)
        }
    }

    @Test func warpedObjectsComeBackWithTheirGrid() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        var points = WarpShape.points(warp: true, quad: [CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 50), CGPoint(x: 20, y: 50)])
        points[5].y -= 12
        points[6].x += 9
        layer.setSmartObjectWarp(.warp(points))
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        guard case .warp(let back) = try #require(read.canvasWarp) else { Issue.record("not warped"); return }
        for (a, b) in zip(back, points) { #expect(hypot(a.x - b.x, a.y - b.y) < 0.01) }
    }

    @Test func aBendStaysWhenTheContentsChange() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.setSmartObjectWarp(.perspective([CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 18), CGPoint(x: 64, y: 50), CGPoint(x: 16, y: 44)]))
        let size = layer.image.size
        var contents = try #require(layer.smartObject?.contents)
        contents.layers.removeLast()
        layer.setSmartObjectContents(contents)
        #expect(layer.image.size == size)
        #expect(layer.smartObject?.warp != nil)
    }
}
