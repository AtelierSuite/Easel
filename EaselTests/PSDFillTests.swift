import CoreGraphics
import Testing
@testable import Easel

/// Gradient and pattern fill layers drawn from their settings, for those
/// Photoshop kept no pixels for.
@Suite("Photoshop fills")
struct PSDFillTests {
    private let canvas = CGSize(width: 40, height: 20)

    private func stop(_ red: Double, _ green: Double, _ blue: Double, at location: Int32) -> PSDDescriptor.Value {
        .descriptor(PSDDescriptor(classID: "Clrt", items: [
            ("Clr ", .descriptor(PSDDescriptor(classID: "RGBC", items: [("Rd  ", .double(red)), ("Grn ", .double(green)), ("Bl  ", .double(blue))]))),
            ("Type", .enumerated(type: "Clry", value: "UsrS")), ("Lctn", .integer(location)), ("Mdpn", .integer(50)),
        ]))
    }

    private func opacity(_ percent: Double, at location: Int32) -> PSDDescriptor.Value {
        .descriptor(PSDDescriptor(classID: "TrnS", items: [
            ("Opct", .unit("#Prc", percent)), ("Lctn", .integer(location)), ("Mdpn", .integer(50)),
        ]))
    }

    private func gradient(type: String = "Lnr ", angle: Double = 0, reversed: Bool = false,
                          opacities: [PSDDescriptor.Value]? = nil) -> [UInt8] {
        PSDDescriptor(classID: "null", items: [
            ("Angl", .unit("#Ang", angle)), ("Type", .enumerated(type: "GrdT", value: type)), ("Rvrs", .bool(reversed)),
            ("Grad", .descriptor(PSDDescriptor(classID: "Grdn", items: [
                ("Clrs", .list([stop(255, 0, 0, at: 0), stop(0, 0, 255, at: 4096)])),
                ("Trns", .list(opacities ?? [opacity(100, at: 0), opacity(100, at: 4096)])),
            ]))),
        ]).versionedBytes
    }

    @Test func linearGradientsRunAlongTheirAngle() throws {
        let image = try #require(PSDFills.gradient(gradient(), canvas: canvas, bounds: nil))
        #expect(TestImages.pixel(image, x: 0, y: 10).red > 240)
        #expect(TestImages.pixel(image, x: 39, y: 10).blue > 240)
        let middle = TestImages.pixel(image, x: 20, y: 10)
        #expect(abs(middle.red - middle.blue) < 20)
        // At 90°, from the bottom up.
        let upright = try #require(PSDFills.gradient(gradient(angle: 90), canvas: canvas, bounds: nil))
        #expect(TestImages.pixel(upright, x: 20, y: 19).red > 230)
        #expect(TestImages.pixel(upright, x: 20, y: 0).blue > 230)
        // Reversed, the other way.
        let reversed = try #require(PSDFills.gradient(gradient(reversed: true), canvas: canvas, bounds: nil))
        #expect(TestImages.pixel(reversed, x: 0, y: 10).blue > 240)
    }

    @Test func alignedGradientsSpanTheirShape() throws {
        // Within the right half alone.
        let image = try #require(PSDFills.gradient(gradient(), canvas: canvas, bounds: CGRect(x: 20, y: 0, width: 20, height: 20)))
        #expect(TestImages.pixel(image, x: 10, y: 10).red > 240)
        #expect(TestImages.pixel(image, x: 21, y: 10).red > 200)
        #expect(TestImages.pixel(image, x: 39, y: 10).blue > 230)
    }

    @Test func radialGradientsSpreadFromTheMiddle() throws {
        let image = try #require(PSDFills.gradient(gradient(type: "Rdl "), canvas: canvas, bounds: nil))
        #expect(TestImages.pixel(image, x: 20, y: 10).red > 230)
        #expect(TestImages.pixel(image, x: 0, y: 10).blue > 200)
    }

    @Test func transparencyStopsFade() throws {
        let image = try #require(PSDFills.gradient(
            gradient(opacities: [opacity(100, at: 0), opacity(0, at: 4096)]), canvas: canvas, bounds: nil
        ))
        #expect(TestImages.pixel(image, x: 0, y: 10).alpha > 240)
        #expect(TestImages.pixel(image, x: 39, y: 10).alpha < 15)
    }

    @Test func patternsTileFromTheirPhase() throws {
        let tile = Bitmap.render(size: CGSize(width: 4, height: 4)) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let block = PSDDescriptor(classID: "null", items: [
            ("Ptrn", .descriptor(PSDDescriptor(classID: "Ptrn", items: [("Nm  ", .text("Dots")), ("Idnt", .text("abc"))]))),
            ("Algn", .bool(false)),
            ("phase", .descriptor(PSDDescriptor(classID: "Pnt ", items: [("Hrzn", .double(1)), ("Vrtc", .double(0))]))),
        ]).versionedBytes
        let image = try #require(PSDFills.pattern(block, canvas: canvas, bounds: nil, tiles: ["abc": tile]))
        // Moved a pixel right: the red square sits over x 1 and 2.
        #expect(TestImages.pixel(image, x: 1, y: 0).red > 200)
        #expect(TestImages.pixel(image, x: 0, y: 0).alpha < 15)
        #expect(TestImages.pixel(image, x: 5, y: 1).red > 200)
        #expect(PSDFills.pattern(block, canvas: canvas, bounds: nil, tiles: [:]) == nil)
    }
}
