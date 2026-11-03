import CoreGraphics
import Foundation
import Testing
@testable import Paintbrush

@Suite("Group masks")
struct GroupMaskTests {
    /// A red 8×4 canvas in a group whose mask, a 4×4 square, covers the left
    /// half.
    private func masked(blendMode: LayerBlendMode? = nil) -> Composition {
        let size = CGSize(width: 8, height: 4)
        var group = LayerGroup(name: "Group", blendMode: blendMode)
        group.mask = GroupMask(
            image: LayerImage(TestImages.solid(.white, width: 4, height: 4)),
            transform: LayerTransform(position: CGPoint(x: 2, y: 2))
        )
        var layer = Layer(name: "Red", image: LayerImage(TestImages.solid(RGBAColor(red: 1, green: 0, blue: 0), width: 8, height: 4)), canvasSize: size)
        layer.groupID = group.id
        return Composition(size: size, layers: [layer], groups: [group])
    }

    @Test func masksHideWhatIsInTheGroupPastThem() {
        let image = CompositionRenderer.render(masked())
        #expect(TestImages.isRed(image, x: 1, y: 1))
        #expect(TestImages.isClear(image, x: 6, y: 1))
    }

    /// A masked group that passes through is put together on its own first,
    /// so the mask can cover it.
    @Test func maskedGroupsAreDrawnTogether() throws {
        let items = masked().drawItems
        guard case .group = try #require(items.first) else {
            Issue.record("Expected the masked group to be drawn as one")
            return
        }
    }

    @Test func turnedOffMasksShowEverything() {
        var composition = masked()
        composition.groups[0].mask?.isEnabled = false
        #expect(TestImages.isRed(CompositionRenderer.render(composition), x: 6, y: 1))
    }

    /// The mask goes where the canvas takes the layers.
    @Test func masksFollowTheCanvas() {
        var composition = masked()
        composition.flip(horizontal: true)
        let flipped = CompositionRenderer.render(composition)
        #expect(TestImages.isClear(flipped, x: 1, y: 1))
        #expect(TestImages.isRed(flipped, x: 6, y: 1))

        composition.resizeImage(to: CGSize(width: 16, height: 8))
        let grown = CompositionRenderer.render(composition)
        #expect(TestImages.isClear(grown, x: 4, y: 4))
        #expect(TestImages.isRed(grown, x: 12, y: 4))
    }

    @Test func masksAreSavedWithTheDocument() throws {
        var composition = masked()
        composition.groups[0].mask?.isEnabled = false
        let read = try CompositionArchive.composition(from: try CompositionArchive.fileWrapper(for: composition))
        let mask = try #require(read.groups.first?.mask)
        #expect(mask.isEnabled == false)
        #expect(mask.transform == composition.groups[0].mask?.transform)
        #expect(mask.image.size == CGSize(width: 4, height: 4))
    }
}
