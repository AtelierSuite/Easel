import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Painting")
struct PainterTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    @Test func brushStrokePaintsAlongItsPath() {
        let canvas = TestImages.solid(.clear, width: 20, height: 20)
        let stroke = Stroke(
            points: [StrokePoint(location: CGPoint(x: 2, y: 10)), StrokePoint(location: CGPoint(x: 18, y: 10))],
            settings: BrushSettings(size: 4, color: red), isEraser: false
        )
        let painted = Painter.paint(stroke, onto: canvas)
        #expect(TestImages.isRed(painted, x: 10, y: 10))
        #expect(TestImages.isClear(painted, x: 10, y: 2))
    }

    @Test func eraserClearsAlongItsPath() {
        let canvas = TestImages.solid(red, width: 20, height: 20)
        let stroke = Stroke(
            points: [StrokePoint(location: CGPoint(x: 2, y: 10)), StrokePoint(location: CGPoint(x: 18, y: 10))],
            settings: BrushSettings(size: 4), isEraser: true
        )
        let erased = Painter.paint(stroke, onto: canvas)
        #expect(TestImages.isClear(erased, x: 10, y: 10))
        #expect(TestImages.isRed(erased, x: 10, y: 2))
    }

    @Test func strokeStaysInsideTheSelection() {
        let canvas = TestImages.solid(.clear, width: 20, height: 20)
        let stroke = Stroke(
            points: [StrokePoint(location: CGPoint(x: 0, y: 10)), StrokePoint(location: CGPoint(x: 20, y: 10))],
            settings: BrushSettings(size: 6, color: red), isEraser: false,
            clip: Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 20)))
        )
        let painted = Painter.paint(stroke, onto: canvas)
        #expect(TestImages.isRed(painted, x: 5, y: 10))
        #expect(TestImages.isClear(painted, x: 15, y: 10))
    }

    @Test func overlappingPiecesOfOneStrokeDoNotBuildUp() {
        let canvas = TestImages.solid(.white, width: 20, height: 20)
        // There and back over nearly the same line at half opacity, the way
        // a scribble goes.
        let stroke = Stroke(
            points: [
                StrokePoint(location: CGPoint(x: 2, y: 10)), StrokePoint(location: CGPoint(x: 18, y: 10)),
                StrokePoint(location: CGPoint(x: 2, y: 11)),
            ],
            settings: BrushSettings(size: 4, opacity: 0.5, color: .black), isEraser: false
        )
        let value = TestImages.pixel(Painter.paint(stroke, onto: canvas), x: 10, y: 10).red
        #expect(value >= 100)
        #expect(value <= 160)
    }

    @Test func floodFillStopsAtADifferentColour() throws {
        let filled = try #require(
            Painter.floodFill(TestImages.halves(), at: CGPoint(x: 1, y: 1), with: .black, tolerance: 0.1, clip: nil)
        )
        let left = TestImages.pixel(filled, x: 2, y: 2)
        #expect(left.red < 10 && left.blue < 10)
        #expect(TestImages.isBlue(filled, x: 6, y: 2))
    }

    @Test func floodFillFillsTransparentAreas() throws {
        let filled = try #require(
            Painter.floodFill(TestImages.solid(.clear), at: CGPoint(x: 0, y: 0), with: red, tolerance: 0, clip: nil)
        )
        #expect(TestImages.isRed(filled, x: 7, y: 7))
    }

    @Test func floodFillOffTheImageDoesNothing() {
        #expect(Painter.floodFill(TestImages.halves(), at: CGPoint(x: 40, y: 1), with: red, tolerance: 0, clip: nil) == nil)
    }

    @Test func clearingASelectionLeavesAHole() {
        let selection = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))
        let cleared = Painter.clear(selection, in: TestImages.halves())
        #expect(TestImages.isClear(cleared, x: 1, y: 1))
        #expect(TestImages.isBlue(cleared, x: 6, y: 1))
    }

    @Test func invertedSelectionCoversEverythingElse() {
        let size = CGSize(width: 8, height: 4)
        let selection = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)), isInverted: true)
        let extracted = Painter.extract(selection, from: TestImages.halves())
        #expect(TestImages.isClear(extracted, x: 1, y: 1))
        #expect(TestImages.isBlue(extracted, x: 6, y: 1))
        #expect(selection.bounds(in: size) == CGRect(origin: .zero, size: size))
    }

    @Test func tinySelectionsAreNotKept() {
        #expect(!Selection(shape: .rectangle(CGRect(x: 3, y: 3, width: 1, height: 0))).isMeaningful)
        #expect(Selection(shape: .ellipse(CGRect(x: 3, y: 3, width: 10, height: 10))).isMeaningful)
    }

    @Test func shapesRenderCroppedToThemselves() {
        let spec = ShapeSpec(
            kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 20),
            isFilled: true, lineWidth: 4, color: red
        )
        let rendered = spec.render()
        #expect(rendered.image.width <= 24)
        #expect(rendered.center == CGPoint(x: 20, y: 15))
        #expect(TestImages.isRed(rendered.image, x: rendered.image.width / 2, y: rendered.image.height / 2))
    }

    @Test func textRendersOntoAnImageSizedToIt() {
        let text = TextContent(string: "Hello", fontSize: 40, color: .black)
        let image = TextRenderer.render(text)
        #expect(image.width > 60)
        #expect(image.height > 30 && image.height < 120)
    }
}

@Suite("Text styles")
struct TextStyleTests {
    private let base = TextContent(string: "Hi", fontSize: 40, color: .white)

    @Test func outlineAddsRoomAndColourAroundTheLetters() {
        var outlined = base
        outlined.outline = TextContent.Outline(color: RGBAColor(red: 1, green: 0, blue: 0), width: 0.1)
        let plain = TextRenderer.render(base)
        let image = TextRenderer.render(outlined)
        #expect(image.width > plain.width)
        let pixels = Bitmap.pixels(of: image)!
        var foundRed = false
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let c = pixels.color(x: x, y: y)
                if c.alpha > 250, c.red > 200, c.green < 60 { foundRed = true }
            }
        }
        #expect(foundRed)
    }

    @Test func backgroundFillsBehindTheText() {
        var boxed = base
        boxed.background = TextContent.Background(color: RGBAColor(red: 0, green: 0, blue: 1), padding: 0.3, cornerRadius: 0)
        let image = TextRenderer.render(boxed)
        // Square corners: the very corner of the box is filled blue.
        let corner = TextImages.firstOpaque(in: image)
        #expect(corner != nil)
        #expect(TestImages.isBlue(image, x: image.width / 2, y: 3))
    }

    @Test func oldTextWithoutStylesStillDecodes() throws {
        let json = #"{"string":"A","design":"standard","isBold":true,"isItalic":false,"fontSize":12,"color":{"red":0,"green":0,"blue":0,"alpha":1},"alignment":"center"}"#
        let text = try JSONDecoder().decode(TextContent.self, from: Data(json.utf8))
        #expect(text.outline == nil && text.background == nil)
    }
}

private enum TextImages {
    static func firstOpaque(in image: CGImage) -> (Int, Int)? {
        let pixels = Bitmap.pixels(of: image)!
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.color(x: x, y: y).alpha > 250 { return (x, y) }
        }
        return nil
    }
}
