import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Photoshop adjustment layers")
struct PSDAdjustmentTests {
    private let size = CGSize(width: 20, height: 10)

    private func roundTrip(_ filter: LayerFilter, opacity: Double = 1) throws -> Layer {
        let paper = Layer(name: "Paper", image: LayerImage(TestImages.halves(width: 20, height: 10)), canvasSize: size)
        var composition = Composition(size: size, layers: [paper])
        var adjustment = composition.adjustmentLayer(filter.kind)
        adjustment.adjustment = filter
        adjustment.opacity = opacity
        composition.layers.append(adjustment)
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        return try #require(read.layers.last { $0.isAdjustment })
    }

    @Test(arguments: [
        ("invert", [Double]()), ("posterize", [6]), ("threshold", [90]), ("exposure", [1.25, 0.05, 1.4]),
        ("vibrance", [40, -15]), ("photoFilter", [60, 0]), ("blackAndWhite", [10, 70, 30, 50, 120, -20, 1]),
    ])
    func newerAdjustmentsComeBack(_ kind: String, _ values: [Double]) throws {
        var filter = LayerFilter(kind: LayerFilter.Kind(rawValue: kind)!)
        if !values.isEmpty { filter.values = values }
        if filter.kind.hasColor { filter.color = RGBAColor(red: 0.2, green: 0.6, blue: 0.9) }
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == filter.kind)
        for index in values.indices { #expect(abs(read.value(index) - values[index]) < 0.01) }
        if filter.kind.hasColor, let color = read.color {
            #expect(abs(color.red - 0.2) < 0.01 && abs(color.blue - 0.9) < 0.01)
        }
    }

    @Test func levelsComeBack() throws {
        var filter = LayerFilter(kind: .levels)
        filter.black = 0.2
        filter.white = 0.8
        filter.gamma = 1.5
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == .levels)
        #expect(abs((read.black ?? 0) - 0.2) < 0.01 && abs((read.white ?? 0) - 0.8) < 0.01 && abs((read.gamma ?? 0) - 1.5) < 0.01)
    }

    @Test func curvesComeBack() throws {
        var filter = LayerFilter(kind: .curves)
        filter.curve = [0, 0.1, 0.5, 0.9, 1]
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == .curves)
        for (a, b) in zip(read.curve ?? [], filter.curve!) { #expect(abs(a - b) < 0.01) }
    }

    @Test func hueSaturationComesBack() throws {
        var filter = LayerFilter(kind: .hsl)
        var bands = LayerFilter.neutralHSL
        bands[0] = 0.5
        bands[5 * 3 + 1] = -0.6
        filter.hslBands = bands
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == .hsl)
        #expect(abs((read.hslBands?[0] ?? 0) - 0.5) < 0.02)
        #expect(abs((read.hslBands?[5 * 3 + 1] ?? 0) + 0.6) < 0.02)
    }

    @Test func brightnessAndContrastComeBack() throws {
        var filter = LayerFilter(kind: .contrast)
        filter.amount = 0.4
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == .contrast)
        #expect(abs(read.amount - 0.4) < 0.02)
    }

    @Test func colorBalanceComesBack() throws {
        var filter = LayerFilter(kind: .colorBalance)
        filter.balance = [0.3, -0.2, 0.1]
        let read = try #require(try roundTrip(filter).adjustment)
        for (a, b) in zip(read.balance ?? [], filter.balance!) { #expect(abs(a - b) < 0.01) }
    }

    @Test func blackAndWhiteTakesItsAmountFromOpacity() throws {
        var filter = LayerFilter(kind: .blackAndWhite)
        filter.amount = 0.5
        let layer = try roundTrip(filter, opacity: 0.8)
        #expect(layer.adjustment?.kind == .blackAndWhite)
        #expect(abs(layer.opacity - 0.4) < 0.01)
    }

    @Test func gradientMapsComeBack() throws {
        var filter = LayerFilter(kind: .gradientMap)
        filter.shadowColor = RGBAColor(red: 0.2, green: 0, blue: 0.4)
        filter.highlightColor = RGBAColor(red: 1, green: 0.9, blue: 0.5)
        let read = try #require(try roundTrip(filter).adjustment)
        #expect(read.kind == .gradientMap)
        #expect(abs((read.shadowColor?.blue ?? 0) - 0.4) < 0.01)
        #expect(abs((read.highlightColor?.green ?? 0) - 0.9) < 0.01)
    }

    @Test func masksOverAdjustmentsComeBack() throws {
        let paper = Layer(name: "Paper", image: LayerImage(TestImages.halves(width: 20, height: 10)), canvasSize: size)
        var composition = Composition(size: size, layers: [paper])
        var adjustment = composition.adjustmentLayer(.blackAndWhite)
        adjustment.mask = LayerMask(image: LayerImage(Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }))
        composition.layers.append(adjustment)
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        let image = CompositionRenderer.render(read)
        let left = TestImages.pixel(image, x: 2, y: 5)
        #expect(abs(left.red - left.blue) < 15)
        #expect(TestImages.isBlue(image, x: 15, y: 5))
    }
}
