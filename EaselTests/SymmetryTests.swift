import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Symmetry")
struct SymmetryTests {
    private let size = CGSize(width: 100, height: 60)

    @Test func eachSettingMakesItsNumberOfStrokes() {
        let stroke = Stroke(points: [StrokePoint(location: CGPoint(x: 10, y: 5))], settings: BrushSettings(size: 4), kind: .paint)
        #expect(Symmetry.off.strokes(for: stroke, in: size).count == 1)
        #expect(Symmetry.vertical.strokes(for: stroke, in: size).count == 2)
        #expect(Symmetry.both.strokes(for: stroke, in: size).count == 4)
    }

    @Test func reflectionsLandAcrossTheMiddle() {
        let stroke = Stroke(points: [StrokePoint(location: CGPoint(x: 10, y: 5))], settings: BrushSettings(size: 4), kind: .paint)
        let points = Symmetry.both.strokes(for: stroke, in: size).map { $0.points[0].location }
        #expect(points == [
            CGPoint(x: 10, y: 5), CGPoint(x: 90, y: 5), CGPoint(x: 10, y: 55), CGPoint(x: 90, y: 55),
        ])
    }

    @Test func aPencilsLeanIsMirroredToo() throws {
        var point = StrokePoint(location: CGPoint(x: 10, y: 5))
        point.azimuth = 0.3
        let stroke = Stroke(points: [point], settings: BrushSettings(size: 4), kind: .paint)
        let mirrored = Symmetry.vertical.strokes(for: stroke, in: size)[1]
        // Leaning right becomes leaning left.
        let azimuth = try #require(mirrored.points[0].azimuth)
        #expect(abs(cos(azimuth) + cos(0.3)) < 0.0001)
        #expect(abs(sin(azimuth) - sin(0.3)) < 0.0001)
    }
}

@MainActor
@Suite("Symmetry painting")
struct SymmetryPaintingTests {
    @Test func aMirroredStrokePaintsBothSidesAsOneEdit() async throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 100, height: 60))
        composition.layers[0].image = LayerImage(Bitmap.render(size: CGSize(width: 100, height: 60)) { _ in })
        nonisolated(unsafe) var published = composition
        nonisolated(unsafe) var edits = 0
        state.attach(to: composition) { published = $0 }
        state.edited = { _, _ in edits += 1 }
        state.tool = .brush
        state.brush.size = 6
        state.symmetry = .vertical
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 20, y: 30))])
        #expect(state.mirrored(state.activeStroke!).count == 2)
        state.toolEnded(isTap: false, at: CGPoint(x: 20, y: 30))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let image = published.layers[0].image.cgImage
        #expect(TestImages.pixel(image, x: 15, y: 20).alpha > 200)
        #expect(TestImages.pixel(image, x: 85, y: 20).alpha > 200)
        #expect(TestImages.pixel(image, x: 50, y: 20).alpha < 5)
        #expect(edits == 1)
        #expect(state.pendingStrokes.isEmpty)
    }
}
