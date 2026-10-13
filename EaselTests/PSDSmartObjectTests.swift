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

    @Test func cylindersComeBackAsCylinders() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        let corners = [CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 44), CGPoint(x: 20, y: 44)]
        let shape = WarpShape.cylinder(corners: corners, depth: 0.2)
        layer.setSmartObjectWarp(shape)
        let read = try #require(try roundTrip([layer]).layers.first)
        guard case .cylinder(let back) = try #require(read.canvasWarp) else { Issue.record("not a cylinder"); return }
        for (a, b) in zip(back, shape.handles) { #expect(hypot(a.x - b.x, a.y - b.y) < 0.01) }
    }

    @Test func aCylinderCrowdsThePictureToItsSides() {
        let shape = WarpShape.cylinder(corners: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)], depth: 0.2)
        // The middle of the top dips the curve's depth; its corners stay.
        #expect(abs(shape.point(0.5, 0).y - 10) < 1e-6)
        #expect(abs(shape.point(0, 0).y) < 1e-6 && abs(shape.point(1, 1).x - 100) < 1e-6)
        // A quarter of the way across the picture is nearer the side.
        #expect(abs(shape.point(0.25, 0.5).x - (50 - 50 * sin(Double.pi / 4))) < 1e-6)
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

    /// A pixel layer waiting for the file `smart`'s contents were in.
    private func waiting(for smart: Layer) throws -> Layer {
        let block = try #require(PSDSmartObjects.blocks(for: smart, id: "linked").first { $0.key == "SoLd" }?.data)
        var layer = Layer(name: "Linked", image: LayerImage(Bitmap.solid(size: CGSize(width: 20, height: 20), color: .white)),
                          transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.missingLink = SmartObjectLink(fileName: "picture.png", placement: Data(block))
        return layer
    }

    @Test func aChosenFileMakesTheLayerItsSmartObject() throws {
        let smart = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 2))
        var layer = try waiting(for: smart)
        // Hide the right half of the layer as it was.
        layer.mask = LayerMask(image: LayerImage(Bitmap.render(size: CGSize(width: 20, height: 20)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        }))
        let file = try ImageCodec.encode(TestImages.solid(RGBAColor(red: 0, green: 1, blue: 0), width: 20, height: 20), as: .png)
        let relinked = try #require(PSDSmartObjects.relinked(layer, file: [UInt8](file)))
        #expect(relinked.isSmartObject)
        #expect(relinked.missingLink == nil)
        #expect(abs(relinked.transform.scaleX - 2) < 0.001)
        let image = CompositionRenderer.render(Composition(size: size, layers: [relinked]))
        // Shown where the mask showed, on the canvas as before.
        #expect(TestImages.pixel(image, x: 35, y: 30).green > 240)
        #expect(TestImages.pixel(image, x: 45, y: 30).alpha < 10)
        // Out past the old layer, the mask shows the larger contents.
        #expect(TestImages.pixel(image, x: 25, y: 30).green > 240)
    }

    @Test func aFileThatIsNotAPictureLeavesTheLayer() throws {
        let layer = try waiting(for: smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30))))
        #expect(PSDSmartObjects.relinked(layer, file: Array("not a picture".utf8)) == nil)
    }

    @Test func aMissingLinkIsSavedWithThePicture() throws {
        let layer = try waiting(for: smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30))))
        let data = try CompositionArchive.data(for: Composition(size: size, layers: [layer]), original: nil)
        let read = try CompositionArchive.composition(from: data, original: nil)
        #expect(read.layers.first?.missingLink == layer.missingLink)
    }

    @Test func aFilterMaskComesBackAndHidesTheFilters() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 2))
        var curves = LayerFilter(kind: .curves)
        curves.curve = [1, 1, 1, 1, 1]
        layer.filters = [curves]
        // The filters show only on the right half.
        layer.filterMask = LayerMask(image: LayerImage(Bitmap.render(size: CGSize(width: 20, height: 20)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 20))
        }))
        let before = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        #expect(read.filterMask?.isEnabled == true)
        let after = CompositionRenderer.render(Composition(size: size, layers: [read]))
        // Red where the mask hides the curve, white where it lets it through.
        #expect(TestImages.pixel(after, x: 25, y: 15).green < 80)
        #expect(TestImages.pixel(after, x: 50, y: 40).green > 235)
        for (x, y) in [(25, 15), (50, 40), (35, 25), (45, 45)] {
            #expect(abs(Int(TestImages.pixel(before, x: x, y: y).green) - Int(TestImages.pixel(after, x: x, y: y).green)) < 10)
        }
    }

    @Test func aTurnedOffFilterMaskStaysOff() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [LayerFilter(kind: .gaussianBlur)]
        layer.filterMask = LayerMask(image: LayerImage(Bitmap.solid(size: CGSize(width: 20, height: 20), color: .clear)), isEnabled: false)
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.filterMask?.isEnabled == false)
    }

    @Test func aFilterMaskIsSavedWithThePicture() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [LayerFilter(kind: .gaussianBlur)]
        layer.filterMask = LayerMask(image: LayerImage(Bitmap.solid(size: CGSize(width: 20, height: 20), color: .white)), isEnabled: false)
        let data = try CompositionArchive.data(for: Composition(size: size, layers: [layer]), original: nil)
        let read = try CompositionArchive.composition(from: data, original: nil)
        #expect(read.layers.first?.filterMask?.isEnabled == false)
        #expect(read.layers.first?.filterMask?.image.size == CGSize(width: 20, height: 20))
    }

    @Test(arguments: [
        "boxBlur", "blur", "blurMore", "average", "surfaceBlur", "smartBlur", "sharpen", "sharpenMore", "sharpenEdges",
        "median", "minimum", "maximum", "dustAndScratches", "addNoise", "reduceNoise", "despeckle",
        "offset", "custom", "findEdges", "traceContour", "fragment", "facet", "wind", "diffuse", "tiles", "extrude",
        "crystallize", "pointillize", "mezzotint", "halftone", "emboss",
        "spherize", "polarCoordinates", "shear", "zigzag", "ripple", "wave", "spinBlur", "deInterlace", "ntscColors",
        "clouds", "differenceClouds", "fibers", "lensFlare", "channelMixer", "desaturate", "equalize",
    ])
    func photoshopsFiltersComeBack(_ kind: String) throws {
        var filter = LayerFilter(kind: LayerFilter.Kind(rawValue: kind)!)
        // Photoshop keeps this radius in whole pixels: two, on a layer
        // forty across.
        if filter.kind == .dustAndScratches { filter.values = [50, 4] }
        // These too, in whole pixels Photoshop allows.
        if filter.kind == .halftone { filter.values = [250, 108, 162, 90, 45] }
        if filter.kind == .crystallize || filter.kind == .pointillize { filter.values = [250] }
        if filter.kind == .offset { filter.values = [100, -75, 2] }
        if filter.kind == .extrude { filter.values = [1, 250, 40, 1] }
        if filter.kind == .emboss { filter.values = [75] }
        if filter.kind == .fragment { filter.values = [100] }
        if filter.kind == .wave { filter.values = [5, 250, 2500, 125, 875, 100, 100, 0, 1] }
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 2))
        layer.filters = [filter]
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        #expect(read.filters.map(\.kind) == [filter.kind])
        for index in filter.kind.parameters.indices {
            #expect(abs(read.filters[0].value(index) - filter.value(index)) < 0.6)
        }
    }

    @Test func liquifyComesBackWithItsMesh() throws {
        var filter = LayerFilter(kind: .liquify)
        let mesh = FilterMesh.sampling(columns: 64, rows: 64) { x, y in SIMD2(0.1 * sin(y * 3), -0.05 * x) }
        filter.mesh = mesh
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30), scaleX: 2, scaleY: 1.5))
        layer.filters = [filter]
        let read = try #require(try roundTrip([layer]).layers.first?.filters.first)
        #expect(read.kind == .liquify)
        let back = try #require(read.mesh)
        for (x, y) in [(0.2, 0.3), (0.5, 0.5), (0.8, 0.6)] {
            let a = mesh.offset(x: x, y: y), b = back.offset(x: x, y: y)
            #expect(abs(a.x - b.x) < 0.005 && abs(a.y - b.y) < 0.005)
        }
    }

    @Test func shadowsHighlightsComeFromPhotoshop() throws {
        func tone(_ amount: Double, _ width: Double, _ radius: Int32) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: "adaptCorrectTones", items: [
                ("Amnt", .unit("#Prc", amount)), ("Wdth", .unit("#Prc", width)), ("Rds ", .integer(radius)),
            ]))
        }
        let settings = PSDDescriptor(classID: "adaptCorrect", items: [
            ("sdwM", tone(60, 40, 20)), ("hglM", tone(25, 30, 10)), ("BlcC", .double(0.5)), ("WhtC", .double(0.2)),
            ("Cntr", .integer(-10)), ("ClrC", .integer(35)),
        ])
        var filter = LayerFilter(kind: .shadowsHighlights)
        filter.photoshopFilter = PhotoshopFilterRecord(id: 1, name: "Shadows/Highlights...", settings: Data(settings.versionedBytes))
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [filter]
        let read = try #require(try roundTrip([layer]).layers.first?.filters.first)
        #expect(read.kind == .shadowsHighlights)
        // The radii are in the layer's pixels, twenty across here.
        let expected: [Double] = [60, 40, 1000, 25, 30, 500, 35, -10, 0.5, 0.2]
        for (index, value) in expected.enumerated() { #expect(abs(read.value(index) - value) < 0.01) }
        #expect(read.photoshopFilter?.id == 1)
    }

    @Test func aFilterLeftAloneGoesBackAsPhotoshopHadIt() throws {
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [LayerFilter(kind: .reduceNoise)]
        let first = try #require(try roundTrip([layer]).layers.first)
        let record = try #require(first.filters.first?.photoshopFilter)
        let second = try #require(try roundTrip([first]).layers.first)
        #expect(second.filters.first?.photoshopFilter == record)
    }

    @Test(arguments: ["invert", "solarize", "posterize", "threshold", "blackAndWhite"])
    func newerAdjustmentsComeBackAsSmartFilters(_ kind: String) throws {
        let filter = LayerFilter(kind: LayerFilter.Kind(rawValue: kind)!)
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [filter]
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        #expect(read.filters.map(\.kind) == [filter.kind])
        #expect(read.filters.first?.values == filter.values)
    }

    @Test(arguments: ["hsl", "colorBalance", "gradientMap"])
    func adjustmentsComeBackAsSmartFilters(_ kind: String) throws {
        var filter = LayerFilter(kind: LayerFilter.Kind(rawValue: kind)!)
        switch filter.kind {
        case .hsl:
            var bands = LayerFilter.neutralHSL
            bands[0] = 0.5
            bands[5 * 3 + 1] = -0.6
            filter.hslBands = bands
        case .colorBalance:
            filter.balance = [0.4, -0.2, 0.3]
        default:
            filter.amount = 0.6
            filter.shadowColor = RGBAColor(red: 0, green: 0, blue: 0.5)
            filter.highlightColor = RGBAColor(red: 1, green: 0.9, blue: 0.2)
        }
        var layer = smartLayer(transform: LayerTransform(position: CGPoint(x: 40, y: 30)))
        layer.filters = [filter]
        let before = CompositionRenderer.render(Composition(size: size, layers: [layer]))
        let read = try #require(try roundTrip([layer]).layers.first)
        #expect(read.isSmartObject)
        #expect(read.filters.map(\.kind) == [filter.kind])
        let after = CompositionRenderer.render(Composition(size: size, layers: [read]))
        for (x, y) in [(35, 25), (45, 35)] {
            let p = TestImages.pixel(before, x: x, y: y), q = TestImages.pixel(after, x: x, y: y)
            #expect(abs(p.red - q.red) < 6 && abs(p.green - q.green) < 6 && abs(p.blue - q.blue) < 6)
        }
    }
}
