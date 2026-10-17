import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Guides")
struct GuideTests {
    private func composition() -> Composition {
        var composition = Composition.blank(size: CGSize(width: 100, height: 60))
        composition.guides = [Guide(axis: .vertical, position: 30), Guide(axis: .horizontal, position: 10)]
        return composition
    }

    @Test func guidesFollowACropAndFallOffWithIt() {
        var cropped = composition()
        cropped.crop(to: CGRect(x: 20, y: 20, width: 50, height: 40))
        // The upright guide moves in by 20; the level one is cut away.
        #expect(cropped.guides.map(\.axis) == [.vertical])
        #expect(cropped.guides.first?.position == 10)
    }

    @Test func guidesTurnWithTheCanvas() {
        var turned = composition()
        turned.rotate(clockwise: true)
        // An upright line at x 30 becomes a level one at y 30; the level one
        // at y 10 becomes upright, 10 in from the new right edge.
        #expect(turned.guides.contains { $0.axis == .horizontal && abs($0.position - 30) < 0.001 })
        #expect(turned.guides.contains { $0.axis == .vertical && abs($0.position - 50) < 0.001 })
    }

    @Test func guidesAreSavedWithThePicture() throws {
        let original = composition()
        let read = try CompositionArchive.composition(from: CompositionArchive.fileWrapper(for: original))
        #expect(read.guides == original.guides)
    }

    @Test func rulerStepsAreRoundNumbers() {
        #expect(Rulers.niceStep(37) == 50)
        #expect(Rulers.niceStep(120) == 200)
        #expect(Rulers.niceStep(0.7) == 1)
    }
}

@MainActor
@Suite("Guide editing")
struct GuideEditingTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 100, height: 100))
        composition.layers[0].image = LayerImage(TestImages.solid(.white, width: 20, height: 20))
        composition.layers[0].transform = LayerTransform(position: CGPoint(x: 10, y: 10))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        state.viewportSize = CGSize(width: 100, height: 100)
        state.tool = .move
        return (state, { published })
    }

    @Test func theMoveToolDragsAGuideAndDropsItOffTheCanvasToRemoveIt() {
        let (state, published) = host()
        state.addGuide(.vertical, at: 70)
        state.toolBegan(at: CGPoint(x: 71, y: 50), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 80, y: 50))])
        state.toolEnded(isTap: false, at: CGPoint(x: 80, y: 50))
        #expect(published().guides.first?.position == 80)
        // The layer stayed put.
        #expect(published().layers[0].transform.position == CGPoint(x: 10, y: 10))
        state.toolBegan(at: CGPoint(x: 80, y: 50), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 120, y: 50))])
        state.toolEnded(isTap: false, at: CGPoint(x: 120, y: 50))
        #expect(published().guides.isEmpty)
    }

    @Test func layersSnapToGuides() {
        let (state, published) = host()
        state.addGuide(.vertical, at: 73)
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        // Right edge to 76, three past the guide and nearer it than any
        // other line.
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 66, y: 10))])
        #expect(published().layers[0].transform.position.x == 63)
    }

    @Test func aGuideOffTheCanvasIsNotAdded() {
        let (state, published) = host()
        state.addGuide(.horizontal, at: 140)
        #expect(published().guides.isEmpty)
    }
}
