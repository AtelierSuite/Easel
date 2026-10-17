import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@MainActor
@Suite("Stroke preview")
struct StrokePreviewTests {
    private func stroke(_ tip: BrushTip, eraser: Bool = false) -> Stroke {
        var settings = BrushSettings(size: 10)
        settings.tip = tip
        return Stroke(points: [StrokePoint(location: CGPoint(x: 5, y: 5))], settings: settings, isEraser: eraser)
    }

    @Test func strokesShowInTheOrderTheyWereDrawn() {
        // A marker, then a round stroke over it, then another marker: three
        // runs, not the markers drawn together over the round stroke.
        let runs = CanvasView.strokeRuns([
            stroke(.marker), stroke(.round), stroke(.round, eraser: true), stroke(.marker), stroke(.marker),
            stroke(.neon),
        ])
        #expect(runs.map(\.mode) == [.multiply, .normal, .multiply, .plusLighter])
        #expect(runs.map(\.start) == [0, 1, 3, 5])
        #expect(runs.map(\.strokes.count) == [1, 2, 2, 1])
    }
}

@MainActor
@Suite("Strokes waiting on effects")
struct LandedStrokeTests {
    @Test func aStrokeStaysShownUntilTheLayersEffectsAreWorkedOutWithIt() async throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 100, height: 60))
        composition.layers[0].image = LayerImage(Bitmap.render(size: CGSize(width: 100, height: 60)) { _ in })
        composition.layers[0].effects = [LayerEffect(kind: .dropShadow)]
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        state.tool = .brush
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 60, y: 30))])
        state.toolEnded(isTap: false, at: CGPoint(x: 60, y: 30))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        // Painted in, but the canvas still shows the layer as it was.
        let layer = try #require(published.layers.first)
        #expect(TestImages.pixel(layer.image.cgImage, x: 35, y: 20).alpha > 200)
        #expect(!state.showsCurrentPixels(of: layer))
        #expect(state.pendingStrokes.count == 1)
        #expect(state.pendingStrokes.allSatisfy { $0.hasLanded })
        // Once it is shown with its effects, the stroke goes.
        _ = state.styledDisplay(for: layer)
        for _ in 0..<200 where !state.pendingStrokes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.showsCurrentPixels(of: layer))
        #expect(state.pendingStrokes.isEmpty)
    }

    @Test func aStrokeOnAPlainLayerGoesAsSoonAsItIsPaintedIn() async throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 100, height: 60))
        composition.layers[0].image = LayerImage(Bitmap.render(size: CGSize(width: 100, height: 60)) { _ in })
        state.attach(to: composition) { _ in }
        state.tool = .brush
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 60, y: 30))])
        state.toolEnded(isTap: false, at: CGPoint(x: 60, y: 30))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.pendingStrokes.isEmpty)
    }
}
