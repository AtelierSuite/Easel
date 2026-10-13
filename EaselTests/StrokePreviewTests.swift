import CoreGraphics
import Foundation
import Testing
@testable import Easel

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
