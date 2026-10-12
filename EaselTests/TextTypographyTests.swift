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
