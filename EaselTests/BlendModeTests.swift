import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Blend modes")
struct BlendModeTests {
    private let size = CGSize(width: 16, height: 16)

    /// A picture of one colour, given as the bytes the app draws in.
    private func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: UInt8 = 255) -> CGImage {
        let premultiplied = [red, green, blue].map { UInt8((Int($0) * Int(alpha) + 127) / 255) }
        let bytes = (0..<(16 * 16)).flatMap { _ in premultiplied + [alpha] }
        return PixelBuffer(width: 16, height: 16, bytes: bytes).makeImage()!
    }

    private func mixed(_ mode: LayerBlendMode, topAlpha: UInt8 = 255) -> PixelBuffer {
        let back = Layer(name: "Back", image: LayerImage(solid(153, 102, 51)), canvasSize: size)
        var top = Layer(name: "Top", image: LayerImage(solid(77, 179, 128, alpha: topAlpha)), canvasSize: size)
        top.blendMode = mode
        return Bitmap.pixels(of: CompositionRenderer.render(Composition(size: size, layers: [back, top])))!
    }

    @Test(arguments: [
        (LayerBlendMode.linearLight, [52, 205, 52]),
        (.vividLight, [86, 171, 51]),
        (.pinLight, [153, 103, 51]),
        (.hardMix, [0, 255, 0]),
        (.subtract, [76, 0, 0]),
        (.divide, [255, 145, 102]),
        (.darkerColor, [153, 102, 51]),
        (.lighterColor, [77, 179, 128]),
    ])
    func photoshopsFormulas(mode: LayerBlendMode, expected: [Int]) {
        let pixels = mixed(mode)
        for channel in 0..<3 {
            #expect(abs(Int(pixels.bytes[channel]) - expected[channel]) <= 2, "\(mode) channel \(channel)")
        }
        #expect(pixels.bytes[3] == 255)
    }

    @Test func fadedLayersMixInPart() {
        // Half the layer shows: halfway between the backdrop and the mix.
        let pixels = mixed(.subtract, topAlpha: 128)
        #expect(abs(Int(pixels.bytes[0]) - (153 + 76) / 2) <= 3)
        #expect(abs(Int(pixels.bytes[1]) - 102 / 2) <= 3)
    }

    @Test func dissolveShowsWholePixelsTheSameEachTime() {
        let first = mixed(.dissolve, topAlpha: 128)
        #expect(first.bytes == mixed(.dissolve, topAlpha: 128).bytes)
        var shown = 0
        for index in 0..<(16 * 16) {
            let pixel = first.bytes[(index * 4)..<(index * 4 + 4)].map(Int.init)
            #expect(pixel[3] == 255)
            // Whole pixels of the layer, or none of it; the layer's colour
            // comes back from half opacity within a step or two.
            if abs(pixel[0] - 77) <= 2 && abs(pixel[1] - 179) <= 2 && abs(pixel[2] - 128) <= 2 {
                shown += 1
            } else {
                #expect(Array(pixel.prefix(3)) == [153, 102, 51])
            }
        }
        // About half of them, as the layer is about half there.
        #expect(shown > 64 && shown < 192)
    }

    @Test func modesSurviveAPhotoshopRoundTrip() throws {
        let modes = LayerBlendMode.groups.flatMap { $0 }
        #expect(Set(modes) == Set(LayerBlendMode.allCases))
        let layers = modes.map { mode in
            var layer = Layer(name: mode.rawValue, image: LayerImage(solid(200, 100, 50)), canvasSize: size)
            layer.blendMode = mode
            return layer
        }
        let read = try PSDReader.composition(from: try PSDWriter.data(for: Composition(size: size, layers: layers)))
        #expect(read.layers.map(\.blendMode) == modes)
    }
}
