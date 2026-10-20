import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Easel
@testable import Paintbrush

@Suite("Text typography")
struct TextTypographyTests {
    private func text(_ string: String = "Hello", size: Double = 40) -> TextContent {
        TextContent(string: string, fontSize: size, color: .black)
    }

    @Test func aPickedFamilySetsTheFont() {
        var content = text()
        content.fontName = "Courier New"
        content.isBold = false
        #expect(TextRenderer.font(for: content).familyName == "Courier New")
        content.isBold = true
        #expect(TextRenderer.font(for: content).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func aMissingFamilyFallsBackToTheSystemFont() {
        var content = text()
        content.fontName = "No Such Font Family"
        #expect(TextRenderer.font(for: content).familyName == UIFont.systemFont(ofSize: 40).familyName)
    }

    @Test func theFamilyIsSaved() throws {
        var content = text()
        content.fontName = "Georgia"
        let layer = Layer(name: "Text", image: LayerImage(TextRenderer.render(content)), text: content,
                          transform: LayerTransform(position: CGPoint(x: 50, y: 50)))
        let composition = Composition(size: CGSize(width: 100, height: 100), layers: [layer])
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers[0].text?.fontName == "Georgia")
    }
}

@Suite("Text spacing")
struct TextSpacingTests {
    private func width(_ content: TextContent) -> Int { TextRenderer.render(content).width }
    private func height(_ content: TextContent) -> Int { TextRenderer.render(content).height }

    @Test func trackingSpreadsTheLetters() {
        let plain = TextContent(string: "Spacing", fontSize: 40, color: .black)
        var spread = plain
        spread.tracking = 0.5
        var tight = plain
        tight.tracking = -0.1
        #expect(width(spread) > width(plain) + 60)
        #expect(width(tight) < width(plain))
    }

    @Test func lineSpacingSpreadsTheLines() {
        let plain = TextContent(string: "One\nTwo\nThree", fontSize: 40, color: .black)
        var loose = plain
        loose.lineSpacing = 2
        #expect(height(loose) > height(plain) + 60)
    }

    @Test func kerningCanBeTurnedOff() {
        let plain = TextContent(string: "AVAVAVAV", fontSize: 80, color: .black)
        var unkerned = plain
        unkerned.usesKerning = false
        #expect(width(unkerned) > width(plain))
    }
}

@Suite("Paragraph text")
struct ParagraphTextTests {
    private let words = "A line of words long enough to wrap onto several lines in a narrow box"

    @Test func aBoxWrapsLinesToItsWidth() {
        let line = TextContent(string: words, fontSize: 30, color: .black)
        var boxed = line
        boxed.boxWidth = 300
        let plain = TextRenderer.render(line), wrapped = TextRenderer.render(boxed)
        #expect(wrapped.width < plain.width / 2)
        #expect(wrapped.height > plain.height * 2)
        // The box keeps its width, give or take the room round it.
        #expect(abs(Double(wrapped.width) - 300) < 30)
    }

    @Test func resizingThePictureResizesTheBox() {
        var content = TextContent(string: words, fontSize: 30, color: .black)
        content.boxWidth = 300
        let layer = Layer(name: "Text", image: LayerImage(TextRenderer.render(content)), text: content,
                          transform: LayerTransform(position: CGPoint(x: 200, y: 200)))
        var composition = Composition(size: CGSize(width: 400, height: 400), layers: [layer])
        composition.resizeImage(to: CGSize(width: 800, height: 800))
        #expect(composition.layers[0].text?.boxWidth == 600)
    }
}

@Suite("Character styling")
struct CharacterStyleTests {
    private func content(_ string: String = "Hello World") -> TextContent {
        TextContent(string: string, fontSize: 40, color: .black)
    }

    @Test func restylingAffectsOnlyThePickedCharacters() {
        var text = content()
        text.restyle(NSRange(location: 6, length: 5)) { $0.color = RGBAColor(red: 1, green: 0, blue: 0) }
        #expect(text.runs == [TextRun(location: 6, length: 5, style: .init(color: RGBAColor(red: 1, green: 0, blue: 0)))])
        #expect(text.style(in: NSRange(location: 0, length: 5)).color == nil)
        #expect(text.style(in: NSRange(location: 7, length: 2)).color == RGBAColor(red: 1, green: 0, blue: 0))
        // Mixed picks share nothing.
        #expect(text.style(in: NSRange(location: 4, length: 4)).color == nil)
    }

    @Test func neighbouringRunsAlikeJoin() {
        var text = content()
        text.restyle(NSRange(location: 0, length: 3)) { $0.isBold = true }
        text.restyle(NSRange(location: 3, length: 2)) { $0.isBold = true }
        #expect(text.runs?.count == 1)
        #expect(text.runs?.first?.length == 5)
    }

    @Test func clearingTakesStylingOff() {
        var text = content()
        text.restyle(NSRange(location: 0, length: 5)) { $0.isUnderlined = true }
        text.clearStyle(NSRange(location: 0, length: 5))
        #expect(text.runs == nil)
    }

    @Test func typingKeepsRunsOnTheirCharacters() {
        var text = content()
        text.restyle(NSRange(location: 6, length: 5)) { $0.isBold = true }
        // Typed before the run: it moves along.
        text.setString("Oh Hello World")
        #expect(text.runs?.first?.location == 9)
        #expect(text.runs?.first?.length == 5)
        // Typed inside it: the run grows.
        text.setString("Oh Hello Wonderful World".replacingOccurrences(of: "Wonderful World", with: "Worrrld"))
        #expect(text.runs?.first?.location == 9)
        #expect(text.runs?.first?.length == 7)
        // Deleted: the run shrinks to what is left.
        text.setString("Oh Hello Wo")
        #expect(text.runs?.first?.length == 2)
    }

    @Test func styledCharactersDrawDifferently() {
        let plain = content("WWWW")
        var big = plain
        big.restyle(NSRange(location: 0, length: 2)) { $0.sizeScale = 2 }
        #expect(TextRenderer.render(big).width > TextRenderer.render(plain).width + 40)
        var red = plain
        red.restyle(NSRange(location: 0, length: 4)) { $0.color = RGBAColor(red: 1, green: 0, blue: 0) }
        let image = TextRenderer.render(red)
        let sawRed = (0..<image.height).contains { y in (0..<image.width).contains { x in TestImages.isRed(image, x: x, y: y) } }
        #expect(sawRed)
    }

    @Test func kerningMovesLettersApart() {
        let plain = content("ABCD")
        var kerned = plain
        kerned.restyle(NSRange(location: 1, length: 1)) { $0.kerning = 1 }
        #expect(TextRenderer.render(kerned).width > TextRenderer.render(plain).width + 30)
    }

    @Test func kerningAddsToTracking() {
        var plain = content("ABCD")
        plain.tracking = 0.2
        var kerned = plain
        kerned.restyle(NSRange(location: 1, length: 1)) { $0.kerning = 1 }
        #expect(TextRenderer.render(kerned).width > TextRenderer.render(plain).width + 30)
        // Words written to a file space the letters as the picture does.
        let spacing = TextRenderer.setRuns(for: kerned).runs.map(\.spacing)
        #expect(spacing.contains { abs($0 - 1.2 * 40) < 0.01 })
        #expect(spacing.contains { abs($0 - 0.2 * 40) < 0.01 })
    }

    @Test func runsAreSaved() throws {
        var text = content()
        text.restyle(NSRange(location: 0, length: 5)) { $0.baselineShift = 0.3; $0.isItalic = true }
        let layer = Layer(name: "Text", image: LayerImage(TextRenderer.render(text)), text: text,
                          transform: LayerTransform(position: CGPoint(x: 50, y: 50)))
        let composition = Composition(size: CGSize(width: 100, height: 100), layers: [layer])
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        #expect(read.layers[0].text?.runs == text.runs)
    }
}
