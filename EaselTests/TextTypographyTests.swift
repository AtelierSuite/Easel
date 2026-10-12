import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Easel

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
