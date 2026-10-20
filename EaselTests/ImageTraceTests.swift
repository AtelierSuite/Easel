import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Image Trace")
struct ImageTraceTests {
    /// A black disc on white.
    private func disc() -> CGImage {
        Bitmap.render(size: CGSize(width: 200, height: 200)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(RGBAColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: 50, y: 50, width: 100, height: 100))
        }
    }

    @Test func blackAndWhiteTracesTheShape() throws {
        let paths = ImageTracer.trace(disc(), colors: 2)
        #expect(paths.count == 2)
        // White, the larger, first; the disc on top.
        let shape = try #require(paths.last)
        #expect(shape.fill.map { $0.red < 0.1 } == true)
        #expect(shape.cgPath.contains(CGPoint(x: 100, y: 100)))
        #expect(!shape.cgPath.contains(CGPoint(x: 20, y: 20)))
        // Simplified and smoothed: far fewer points than pixels round it.
        #expect(shape.nodes.count < 120)
        let box = shape.cgPath.boundingBoxOfPath
        #expect(abs(box.width - 100) < 6 && abs(box.minX - 50) < 4)
    }

    @Test func coloursAreFound() {
        let image = Bitmap.render(size: CGSize(width: 90, height: 30)) { context in
            for (index, color) in [RGBAColor(red: 1, green: 0, blue: 0), RGBAColor(red: 0, green: 0.8, blue: 0), RGBAColor(red: 0, green: 0, blue: 1)].enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: index * 30, y: 0, width: 30, height: 30))
            }
        }
        let paths = ImageTracer.trace(image, colors: 4)
        #expect(paths.count >= 3)
        #expect(paths.contains { ($0.fill?.red ?? 0) > 0.8 && ($0.fill?.blue ?? 1) < 0.2 })
    }

    @MainActor @Test func tracingAddsAVectorLayerAndHidesTheOriginal() async throws {
        let state = EditorState()
        let size = CGSize(width: 200, height: 200)
        let layer = Layer(name: "Disc", image: LayerImage(disc()), canvasSize: size)
        state.attach(to: Composition(size: size, layers: [layer])) { _ in }
        state.traceImage(colors: 2)
        for _ in 0..<300 where state.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.composition.layers.count == 2)
        #expect(state.composition.layers[1].isVector)
        #expect(!state.composition.layers[0].isVisible)
    }
}
