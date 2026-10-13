import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Easel

@Suite("Vector layers")
struct VectorLayerTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func square(fill: Bool = true) -> Layer {
        let spec = ShapeSpec(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 30),
                             isFilled: fill, lineWidth: 4, color: red)
        return Layer.vector(VectorPath.shape(spec), name: "Square")
    }

    @Test func shapesBecomeVectorLayersInPlace() {
        let layer = square()
        #expect(layer.isVector)
        let image = CompositionRenderer.render(Composition(size: CGSize(width: 40, height: 40), layers: [layer]))
        #expect(TestImages.isRed(image, x: 20, y: 20))
        #expect(TestImages.isClear(image, x: 5, y: 5))
        #expect(TestImages.isClear(image, x: 35, y: 35))
    }

    @Test func ellipsesAreFourSmoothPoints() throws {
        let spec = ShapeSpec(kind: .ellipse, start: .zero, end: CGPoint(x: 40, y: 20), isFilled: true, lineWidth: 1, color: red)
        let path = try #require(VectorPath.shape(spec).first)
        #expect(path.nodes.count == 4)
        #expect(path.nodes.allSatisfy { $0.isSmooth })
        let box = path.cgPath.boundingBoxOfPath
        #expect(abs(box.width - 40) < 0.5 && abs(box.height - 20) < 0.5)
    }

    @Test func editingPathsKeepsTheRestInPlace() throws {
        var layer = square()
        var content = try #require(layer.vector)
        // Drag one corner out past the old edge.
        content.paths[0].nodes[2].point.x += 20
        layer.setVector(content)
        let image = CompositionRenderer.render(Composition(size: CGSize(width: 60, height: 40), layers: [layer]))
        // The untouched corner is still at the top left.
        #expect(TestImages.isRed(image, x: 12, y: 12))
        #expect(TestImages.isClear(image, x: 8, y: 8))
        // The moved corner reaches further right.
        #expect(TestImages.isRed(image, x: 47, y: 29))
    }

    @Test func vectorsAreSaved() throws {
        let layer = square(fill: false)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try CompositionArchive.fileWrapper(for: Composition(size: CGSize(width: 40, height: 40), layers: [layer]))
            .write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CompositionArchive.composition(from: FileWrapper(url: url))
        #expect(read.layers[0].vector == layer.vector)
    }

    @Test func paintingTurnsAVectorIntoPixels() {
        let layer = square()
        let aligned = layer.aligned(in: CGSize(width: 40, height: 40))
        #expect(aligned.vector == nil)
        #expect(aligned.isAligned(to: CGSize(width: 40, height: 40)))
    }

    @Test func resizingRedrawsVectorsSharply() throws {
        var composition = Composition(size: CGSize(width: 40, height: 40), layers: [square()])
        composition.resizeImage(to: CGSize(width: 80, height: 80))
        let layer = composition.layers[0]
        #expect(abs(layer.transform.scaleX - 1) < 0.0001)
        #expect(layer.image.width > 40)
        let image = CompositionRenderer.render(composition)
        #expect(TestImages.isRed(image, x: 40, y: 40))
        #expect(TestImages.isClear(image, x: 15, y: 15))
    }
}

@MainActor
@Suite("Pen tool")
struct PenToolTests {
    private func editor() -> EditorState {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 400, height: 400)
        state.tool = .pen
        state.shapeLineWidth = 4
        return state
    }

    private func tap(_ state: EditorState, _ x: Double, _ y: Double) {
        state.toolBegan(at: CGPoint(x: x, y: y), pressure: 1)
        state.toolEnded(isTap: true, at: CGPoint(x: x, y: y))
    }

    @Test func tapsMakeCornersAndTheFirstPointCloses() throws {
        let state = editor()
        tap(state, 20, 20)
        tap(state, 120, 20)
        tap(state, 120, 120)
        let layer = try #require(state.activeLayer)
        #expect(layer.isVector)
        #expect(layer.vector?.paths.first?.nodes.count == 3)
        tap(state, 21, 21)
        #expect(state.penPath == nil)
        let path = try #require(state.activeLayer?.vector?.paths.first)
        #expect(path.isClosed)
        #expect(path.nodes.count == 3)
        // The corner points sit where they were tapped on the canvas.
        let corner = path.nodes[1].point.applying(state.activeLayer!.affineTransform)
        #expect(abs(corner.x - 120) < 0.01 && abs(corner.y - 20) < 0.01)
    }

    @Test func draggingMakesASmoothCurve() throws {
        let state = editor()
        tap(state, 20, 100)
        state.toolBegan(at: CGPoint(x: 100, y: 100), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 140, y: 100))])
        state.toolEnded(isTap: false, at: CGPoint(x: 140, y: 100))
        let layer = try #require(state.activeLayer)
        let node = try #require(layer.vector?.paths.first?.nodes.last)
        #expect(node.isSmooth)
        let out = try #require(node.controlOut).applying(layer.affineTransform)
        let into = try #require(node.controlIn).applying(layer.affineTransform)
        #expect(abs(out.x - 140) < 0.01)
        #expect(abs(into.x - 60) < 0.01)
    }

    @Test func finishedPathsLeaveTheNextOneOnTheSameLayer() throws {
        let state = editor()
        tap(state, 20, 20)
        tap(state, 80, 80)
        state.finishPath()
        tap(state, 150, 150)
        tap(state, 180, 120)
        #expect(state.composition.layers.filter(\.isVector).count == 1)
        let layer = try #require(state.activeLayer)
        #expect(layer.vector?.paths.count == 2)
        #expect(layer.vector?.paths[0].isClosed == false)
        // The first path did not move when the layer grew.
        let first = layer.vector!.paths[0].nodes[0].point.applying(layer.affineTransform)
        #expect(abs(first.x - 20) < 0.01 && abs(first.y - 20) < 0.01)
    }

    @Test func pathsCanStartLayersOfTheirOwn() {
        let state = editor()
        state.penAddsToLayer = false
        tap(state, 20, 20)
        tap(state, 80, 80)
        state.finishPath()
        tap(state, 150, 150)
        #expect(state.composition.layers.filter(\.isVector).count == 2)
    }
}

@MainActor
@Suite("Editing points")
struct NodeToolTests {
    /// An editor holding one 100 by 100 square drawn from (50, 50).
    private func editor() -> EditorState {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 400, height: 400)
        state.addShapeLayer(ShapeSpec(kind: .rectangle, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 150),
                                      isFilled: true, lineWidth: 2, color: .black))
        state.tool = .nodes
        return state
    }

    private func canvasPoint(_ state: EditorState, path: Int = 0, node: Int) -> CGPoint {
        let layer = state.activeLayer!
        return layer.vector!.paths[path].nodes[node].point.applying(layer.affineTransform)
    }

    @Test func draggingAPointMovesIt() {
        let state = editor()
        state.toolBegan(at: CGPoint(x: 150, y: 150), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 180, y: 190))])
        state.toolEnded(isTap: false, at: CGPoint(x: 180, y: 190))
        let moved = canvasPoint(state, node: 2)
        #expect(abs(moved.x - 180) < 0.01 && abs(moved.y - 190) < 0.01)
        // The others stay put.
        let still = canvasPoint(state, node: 0)
        #expect(abs(still.x - 50) < 0.01 && abs(still.y - 50) < 0.01)
    }

    @Test func undoingThePathLetsGoOfItsPoints() throws {
        let state = editor()
        let before = state.composition
        state.toolBegan(at: CGPoint(x: 150, y: 150), pressure: 1)
        state.toolEnded(isTap: false, at: CGPoint(x: 150, y: 150))
        state.isSelectingMultiplePoints = true
        state.toolBegan(at: CGPoint(x: 50, y: 50), pressure: 1)
        state.toolEnded(isTap: false, at: CGPoint(x: 50, y: 50))
        #expect(state.selectedNodes.count == 2)
        var blank = before
        blank.layers.removeLast()
        state.write(blank)
        state.showRestored(blank)
        #expect(state.selectedNode == nil)
        #expect(state.additionalNodes.isEmpty)
    }

    @Test func aCancelledDragPutsThePointBack() {
        let state = editor()
        let before = state.activeLayer
        state.toolBegan(at: CGPoint(x: 150, y: 150), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 180, y: 190))])
        state.toolCancelled()
        #expect(state.activeLayer == before)
        #expect(state.vectorDrag == nil)
    }

    @Test func smoothingAddsHandlesAndHandlesMirror() throws {
        let state = editor()
        state.toolBegan(at: CGPoint(x: 150, y: 50), pressure: 1)
        state.toolEnded(isTap: true, at: CGPoint(x: 150, y: 50))
        state.toggleSmooth()
        let node = try #require(state.selectedVectorNode)
        #expect(node.isSmooth && node.controlIn != nil && node.controlOut != nil)
        // Drag the outgoing handle; the incoming one turns to stay in line.
        let layer = try #require(state.activeLayer)
        let out = node.controlOut!.applying(layer.affineTransform)
        state.toolBegan(at: out, pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 150, y: 90))])
        state.toolEnded(isTap: false, at: CGPoint(x: 150, y: 90))
        let after = try #require(state.selectedVectorNode)
        let anchor = after.point
        let inAngle = atan2(after.controlIn!.y - anchor.y, after.controlIn!.x - anchor.x)
        let outAngle = atan2(after.controlOut!.y - anchor.y, after.controlOut!.x - anchor.x)
        #expect(abs(abs(inAngle - outAngle) - .pi) < 0.01)
    }

    @Test func addingAPointKeepsTheShape() throws {
        let state = editor()
        state.toolBegan(at: CGPoint(x: 50, y: 50), pressure: 1)
        state.toolEnded(isTap: true, at: CGPoint(x: 50, y: 50))
        state.insertNodeAfterSelected()
        #expect(state.activeLayer?.vector?.paths[0].nodes.count == 5)
        let middle = canvasPoint(state, node: 1)
        #expect(abs(middle.x - 100) < 0.01 && abs(middle.y - 50) < 0.01)
    }

    @Test func deletingPointsDownToNothingRemovesTheLayer() {
        let state = editor()
        let layers = state.composition.layers.count
        for _ in 0..<3 {
            let point = canvasPoint(state, node: 0)
            state.toolBegan(at: point, pressure: 1)
            state.toolEnded(isTap: true, at: point)
            state.deleteSelectedNode()
        }
        #expect(state.composition.layers.count == layers - 1)
    }

    @Test func coloursChangeOnThePath() throws {
        let state = editor()
        state.updateVectorStyle { $0.stroke = RGBAColor(red: 1, green: 0, blue: 0); $0.fill = nil }
        let path = try #require(state.activeLayer?.vector?.paths.first)
        #expect(path.fill == nil && path.stroke != nil)
        let image = CompositionRenderer.render(state.composition)
        // Hollow now: the middle shows the see-through background.
        #expect(TestImages.pixel(image, x: 100, y: 100).alpha == 0)
        #expect(TestImages.isRed(image, x: 50, y: 100))
    }

    @Test func halvingACurveKeepsItsMiddle() {
        let start = VectorNode(point: .zero, controlOut: CGPoint(x: 0, y: 10))
        let end = VectorNode(point: CGPoint(x: 10, y: 0), controlIn: CGPoint(x: 10, y: 10))
        let split = VectorNode.split(from: start, to: end)
        #expect(split.middle.point == CGPoint(x: 5, y: 7.5))
    }
}

@MainActor
@Suite("Picking several points")
struct MultiplePointTests {
    private func editor() -> EditorState {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 200, height: 200))) { _ in }
        state.viewportSize = CGSize(width: 400, height: 400)
        state.addShapeLayer(ShapeSpec(kind: .rectangle, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 150),
                                      isFilled: true, lineWidth: 2, color: .black))
        state.tool = .nodes
        return state
    }

    private func tap(_ state: EditorState, _ point: CGPoint) {
        state.toolBegan(at: point, pressure: 1)
        state.toolEnded(isTap: true, at: point)
    }

    private func corners(_ state: EditorState) -> [CGPoint] {
        let layer = state.activeLayer!
        return layer.vector!.paths[0].nodes.map { $0.point.applying(layer.affineTransform) }
    }

    @Test func pickedPointsMoveTogether() {
        let state = editor()
        state.isSelectingMultiplePoints = true
        tap(state, CGPoint(x: 150, y: 50))
        tap(state, CGPoint(x: 150, y: 150))
        #expect(state.selectedNodes.count == 2)
        state.toolBegan(at: CGPoint(x: 150, y: 150), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 170, y: 150))])
        state.toolEnded(isTap: false, at: CGPoint(x: 170, y: 150))
        let points = corners(state)
        #expect(abs(points[1].x - 170) < 0.01 && abs(points[2].x - 170) < 0.01)
        #expect(abs(points[0].x - 50) < 0.01 && abs(points[3].x - 50) < 0.01)
    }

    @Test func pickingAnotherWithoutMultipleStartsAfresh() {
        let state = editor()
        tap(state, CGPoint(x: 150, y: 50))
        tap(state, CGPoint(x: 150, y: 150))
        #expect(state.selectedNodes.count == 1)
    }

    @Test func deletingPickedPointsTogether() {
        let state = editor()
        state.selectAllPoints()
        #expect(state.selectedNodes.count == 4)
        state.additionalNodes.removeLast()
        state.deleteSelectedNode()
        // Three of four gone leaves too few for a path, so the layer goes.
        #expect(!state.composition.layers.contains { $0.isVector })
    }
}

@Suite("Combining shapes")
struct VectorBooleanTests {
    private let black = RGBAColor.black

    private func square(_ x: Double, _ y: Double, _ size: Double) -> VectorPath {
        VectorPath.shape(ShapeSpec(kind: .rectangle, start: CGPoint(x: x, y: y), end: CGPoint(x: x + size, y: y + size),
                                   isFilled: true, lineWidth: 1, color: .black))[0]
    }

    private func render(_ path: VectorPath) -> CGImage {
        Bitmap.render(size: CGSize(width: 100, height: 100)) { VectorRenderer.draw(VectorContent(paths: [path]), in: $0) }
    }

    private func filled(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { TestImages.pixel(image, x: x, y: y).alpha > 200 }

    @Test func uniteCoversBoth() throws {
        let path = try #require(VectorBoolean.unite.apply(to: [square(10, 10, 40), square(30, 30, 40)]))
        let image = render(path)
        #expect(filled(image, 15, 15) && filled(image, 65, 65) && filled(image, 40, 40))
        #expect(!filled(image, 65, 15))
    }

    @Test func subtractCutsAHole() throws {
        let path = try #require(VectorBoolean.subtract.apply(to: [square(10, 10, 60), square(30, 30, 20)]))
        #expect(path.extraContours?.count == 1)
        let image = render(path)
        #expect(filled(image, 15, 15))
        #expect(!filled(image, 40, 40))
    }

    @Test func intersectKeepsTheOverlap() throws {
        let path = try #require(VectorBoolean.intersect.apply(to: [square(10, 10, 40), square(30, 30, 40)]))
        let image = render(path)
        #expect(filled(image, 40, 40))
        #expect(!filled(image, 15, 15) && !filled(image, 65, 65))
    }

    @Test func excludeDropsTheOverlap() throws {
        let path = try #require(VectorBoolean.exclude.apply(to: [square(10, 10, 40), square(30, 30, 40)]))
        let image = render(path)
        #expect(filled(image, 15, 15) && filled(image, 65, 65))
        #expect(!filled(image, 40, 40))
    }

    @Test func curvesStayCurves() throws {
        let circle = VectorPath.shape(ShapeSpec(kind: .ellipse, start: .zero, end: CGPoint(x: 40, y: 40), isFilled: true,
                                                lineWidth: 1, color: .black))[0]
        let path = try #require(VectorBoolean.unite.apply(to: [circle, square(20, 20, 40)]))
        #expect(path.nodes.contains { $0.controlIn != nil || $0.controlOut != nil })
    }

    @Test func combiningLetsGoOfTheBottomShapesSettings() throws {
        var rounded = VectorPath.shape(ShapeSpec(kind: .roundedRectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 70),
                                                 isFilled: true, lineWidth: 1, color: .black))[0]
        rounded.text = PathText(string: "Words", fontSize: 12, color: .black)
        #expect(rounded.liveShape != nil)
        let path = try #require(VectorBoolean.subtract.apply(to: [rounded, square(30, 30, 20)]))
        #expect(path.liveShape == nil)
        #expect(path.text == nil)
        #expect(path.extraContours?.count == 1)
    }

    @Test func redrawingALiveShapeDropsOtherOutlines() {
        var path = VectorPath.shape(ShapeSpec(kind: .roundedRectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 70),
                                              isFilled: true, lineWidth: 1, color: .black))[0]
        path.extraContours = [square(30, 30, 20).nodes]
        path.rebuildLiveShape()
        #expect(path.extraContours == nil)
    }

    @Test func oneShapeIsNothingToCombine() {
        #expect(VectorBoolean.unite.apply(to: [square(0, 0, 10)]) == nil)
    }

    @Test func mergingVectorLayersKeepsThemVectors() {
        let a = Layer.vector([square(10, 10, 20)], name: "A")
        let b = Layer.vector([square(50, 50, 20)], name: "B")
        var composition = Composition(size: CGSize(width: 100, height: 100), layers: [a, b])
        composition.mergeDown(b.id)
        #expect(composition.layers.count == 1)
        #expect(composition.layers[0].vector?.paths.count == 2)
        let image = CompositionRenderer.render(composition)
        #expect(filled(image, 15, 15) && filled(image, 60, 60))
    }
}

@Suite("Text on a path")
struct PathTextTests {
    private func line(from: CGPoint, to: CGPoint) -> VectorPath {
        VectorPath(nodes: [VectorNode(point: from), VectorNode(point: to)], isClosed: false, fill: nil, stroke: nil, strokeWidth: 1)
    }

    @Test func lettersFollowAStraightLine() {
        var path = line(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 290, y: 50))
        path.text = PathText(string: "HELLO", fontSize: 30, color: .black)
        let placed = PathTextRenderer.layout(path.text!, along: path)
        #expect(placed.count == 5)
        #expect(placed.allSatisfy { abs($0.angle) < 0.001 && abs($0.point.y - 50) < 0.001 })
        #expect(zip(placed, placed.dropFirst()).allSatisfy { $0.point.x < $1.point.x })
    }

    @Test func lettersTurnWithTheLine() {
        var path = line(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 50, y: 290))
        path.text = PathText(string: "AB", fontSize: 30, color: .black)
        let placed = PathTextRenderer.layout(path.text!, along: path)
        #expect(placed.allSatisfy { abs($0.angle - .pi / 2) < 0.001 })
    }

    @Test func lettersTheSystemFontLacksComeFromTheirOwnFont() {
        var path = line(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 290, y: 50))
        path.text = PathText(string: "夏", fontSize: 30, color: .black)
        let placed = PathTextRenderer.layout(path.text!, along: path)
        #expect(placed.count == 1)
        var character: UniChar = "夏".utf16.first!
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(placed[0].font, &character, &glyph, 1))
        #expect(glyph == placed[0].glyph)
    }

    @Test func textPastTheEndIsLeftOff() {
        var path = line(from: .zero, to: CGPoint(x: 30, y: 0))
        path.text = PathText(string: "A long sentence", fontSize: 30, color: .black)
        #expect(PathTextRenderer.layout(path.text!, along: path).count < 15)
    }

    @Test func textIsDrawnAndSaved() throws {
        var path = line(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 290, y: 60))
        path.text = PathText(string: "WWWW", fontSize: 40, color: RGBAColor(red: 1, green: 0, blue: 0))
        let layer = Layer.vector([path], name: "Words")
        let image = CompositionRenderer.render(Composition(size: CGSize(width: 300, height: 120), layers: [layer]))
        let pixels = Bitmap.pixels(of: image)!
        var red = 0
        for y in 0..<pixels.height { for x in 0..<pixels.width where pixels.color(x: x, y: y).red > 200 && pixels.color(x: x, y: y).alpha > 200 { red += 1 } }
        #expect(red > 200)
        let data = try JSONEncoder().encode(layer.vector)
        #expect(try JSONDecoder().decode(VectorContent.self, from: data) == layer.vector)
    }
}
