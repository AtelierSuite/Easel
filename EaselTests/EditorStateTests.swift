import CoreGraphics
import Foundation
import Testing
@testable import Easel

@MainActor
@Suite("Editor")
struct EditorStateTests {
    /// An editor on its own, its edits kept in `published`.
    @MainActor
    private final class Host {
        let state = EditorState()
        var published: Composition

        init(_ composition: Composition) {
            published = composition
            state.attach(to: composition) { [unowned self] in self.published = $0 }
        }
    }

    @Test func aFirstPictureTakesTheUntouchedCanvasesPlace() {
        let host = Host(.blank(size: CGSize(width: 100, height: 100)))
        host.state.addImageLayers([(TestImages.halves(width: 40, height: 20), "Photo")])
        #expect(host.state.activeLayerID == host.published.layers.first?.id)
        host.state.addImageLayers([(TestImages.halves(), "Second")])
        #expect(host.published.size == CGSize(width: 40, height: 20))
        #expect(host.published.layers.map(\.name) == ["Photo", "Second"])
        #expect(host.state.activeLayerID == host.published.layers.last?.id)
        #expect(host.state.tool == .move)
    }

    @Test func focusingPutsThePointInTheMiddleOfTheClearArea() {
        let host = Host(.blank(size: CGSize(width: 200, height: 100)))
        host.state.viewportSize = CGSize(width: 400, height: 300)
        host.state.canvasInsets = .init(top: 8, leading: 0, bottom: 124, trailing: 0)
        host.state.focus(on: CGPoint(x: 30, y: 80), zoom: 3)
        #expect(host.state.zoom == 3)
        let point = host.state.viewport.screenPoint(CGPoint(x: 30, y: 80))
        #expect(abs(point.x - 200) < 0.001)
        #expect(abs(point.y - (8 + (300 - 8 - 124) / 2)) < 0.001)
    }

    @Test func picturesStackOnADrawnCanvas() {
        var composition = Composition.blank(size: CGSize(width: 100, height: 100))
        composition.layers[0].image = LayerImage(TestImages.solid(.white, width: 100, height: 100))
        let host = Host(composition)
        host.state.addImageLayers([(TestImages.halves(width: 400, height: 200), "Big")])
        #expect(host.published.size == CGSize(width: 100, height: 100))
        #expect(host.published.layers.count == 2)
        // Shrunk to fit, by scale rather than by resampling.
        #expect(host.published.layers[1].transform.scaleX == 0.25)
    }

    @Test func editsInARowEachSeeTheOneBefore() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.addEmptyLayer()
        host.state.addEmptyLayer()
        #expect(host.published.layers.count == 3)
        #expect(Set(host.published.layers.map(\.name)).count == 3)
    }

    /// A host whose file must be saved as a copy before it is edited,
    /// answering with `saves` when asked to save it.
    private func copyingHost(saves: Bool) -> (Host, () -> Int) {
        let host = Host(.blank(size: CGSize(width: 40, height: 20)))
        var hasCopy = false
        var steps = 0
        host.state.edited = { _, _ in steps += 1 }
        host.state.copyBeforeEditing = CopyBeforeEditing(isRequired: { !hasCopy }) { completion in
            hasCopy = saves
            completion(saves)
        }
        return (host, { steps })
    }

    @Test func editsHeldForACopyAllLandOnceItIsSaved() throws {
        let (host, steps) = copyingHost(saves: true)
        let original = host.published
        host.state.addEmptyLayer()
        let added = try #require(host.state.activeLayerID)
        #expect(host.state.isAskingToCopy)
        #expect(host.published == original)
        // What the command did after its edit holds: the new layer is the
        // active one, and edits after it build on it.
        #expect(host.state.composition[added] != nil)
        host.state.updateActiveLayer { $0.opacity = 0.5 }
        host.state.saveCopyForHeldEdit()
        #expect(!host.state.isHoldingEdits)
        #expect(host.published.layers.count == 2)
        #expect(host.published[added]?.opacity == 0.5)
        #expect(steps() == 1)
    }

    @Test func editsHeldForACopyAreTakenBackWithoutOne() {
        let (host, steps) = copyingHost(saves: false)
        let original = host.published
        let layerID = host.state.activeLayerID
        let selected = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)))
        host.state.selection = selected
        host.state.cropToSelection()
        #expect(host.state.composition.size == CGSize(width: 10, height: 10))
        #expect(host.state.selection == nil)
        host.state.addEmptyLayer()
        host.state.saveCopyForHeldEdit()
        #expect(host.state.composition == original)
        #expect(host.state.selection == selected)
        #expect(host.state.activeLayerID == layerID)
        #expect(host.published == original)
        #expect(steps() == 0)
        // Cancelling from the question does the same.
        host.state.addEmptyLayer()
        host.state.cancelHeldEdit()
        #expect(host.state.composition == original)
        #expect(!host.state.isAskingToCopy)
    }

    @Test func aDragCalledOffByTheQuestionStays() {
        let (host, _) = copyingHost(saves: true)
        host.state.tool = .move
        host.state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        host.state.toolMoved(to: [StrokePoint(location: CGPoint(x: 5, y: 1))])
        host.state.toolMoved(to: [StrokePoint(location: CGPoint(x: 9, y: 1))])
        host.state.toolCancelled()
        host.state.saveCopyForHeldEdit()
        #expect(host.published.layers[0].transform.position.x == 28)
    }

    @Test func aLayerMovedDuringAnEditKeepsTheMove() async throws {
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        // Half the canvas's size, doubled to cover it, so the edit lines
        // its pixels up with the canvas anew.
        composition.layers[0].image = LayerImage(TestImages.solid(.white, width: 20, height: 10))
        composition.layers[0].transform = LayerTransform(position: CGPoint(x: 20, y: 10), scaleX: 2, scaleY: 2)
        let host = Host(composition)
        let id = composition.layers[0].id
        host.state.editPixels(of: id) { image, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return Painter.fill(Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 4, height: 20))),
                                with: RGBAColor(red: 1, green: 0, blue: 0), onto: image)
        }
        try await Task.sleep(for: .milliseconds(100))
        host.state.updateTransform { $0.position.x += 4 }
        for _ in 0..<100 where host.state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let layer = try #require(host.published[id])
        #expect(abs(layer.transform.position.x - 24) < 0.001)
        #expect(abs(layer.transform.scaleX - 1) < 0.001)
        let picture = CompositionRenderer.render(host.published)
        #expect(TestImages.isRed(picture, x: 6, y: 10))
        #expect(!TestImages.isRed(picture, x: 10, y: 10))
    }

    @Test func theLastLayerCannotBeDeleted() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        let only = host.published.layers[0].id
        host.state.deleteLayer(only)
        #expect(host.published.layers.count == 1)
    }

    @Test func reorderingFromTheTopFirstList() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.addEmptyLayer()
        let bottom = host.published.layers[0].id
        // Shown top first, the background is row 1; drag it above row 0.
        host.state.moveLayers(fromDisplayed: [1], toDisplayed: 0)
        #expect(host.published.layers.last?.id == bottom)
    }

    @Test func lockedLayersRefusePaint() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.setLocked(true, of: host.published.layers[0].id)
        host.state.tool = .brush
        host.state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        #expect(host.state.activeStroke == nil)
        #expect(host.state.paintingBlocker() != nil)
    }

    @Test func aTapWithTheSelectionToolDeselects() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.selectAll()
        host.state.tool = .select
        host.state.toolBegan(at: CGPoint(x: 2, y: 2), pressure: 1)
        host.state.toolEnded(isTap: true, at: CGPoint(x: 2, y: 2))
        #expect(host.state.selection == nil)
    }

    @Test func draggingTheSelectionToolSelects() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.tool = .select
        host.state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        host.state.toolMoved(to: [StrokePoint(location: CGPoint(x: 6, y: 5))])
        host.state.toolEnded(isTap: false, at: CGPoint(x: 6, y: 5))
        #expect(host.state.selection?.bounds(in: CGSize(width: 10, height: 10)) == CGRect(x: 1, y: 1, width: 5, height: 4))
    }

    @Test func movingDragsTheLayer() {
        let host = Host(.blank(size: CGSize(width: 10, height: 10)))
        host.state.tool = .move
        host.state.toolBegan(at: CGPoint(x: 2, y: 2), pressure: 1)
        host.state.toolMoved(to: [StrokePoint(location: CGPoint(x: 5, y: 6))])
        host.state.toolEnded(isTap: false, at: CGPoint(x: 5, y: 6))
        #expect(host.published.layers[0].transform.position == CGPoint(x: 8, y: 9))
    }

    @Test func cropToolKeepsItsFrameOnTheCanvas() {
        let host = Host(.blank(size: CGSize(width: 100, height: 50)))
        host.state.tool = .crop
        #expect(host.state.cropRect == CGRect(x: 0, y: 0, width: 100, height: 50))
        host.state.cropAspect = .square
        #expect(host.state.cropRect?.width == host.state.cropRect?.height)
        host.state.applyCrop()
        #expect(host.published.size == CGSize(width: 50, height: 50))
    }

    @Test func textToolStartsAnEditableLayer() throws {
        let host = Host(.blank(size: CGSize(width: 200, height: 200)))
        host.state.tool = .text
        host.state.toolEnded(isTap: true, at: CGPoint(x: 100, y: 100))
        let layer = try #require(host.state.activeLayer)
        #expect(layer.isText)
        #expect(host.state.presentedPanel == .text)
        host.state.updateText { $0.string = "Easel" }
        #expect(host.published.layers.last?.text?.string == "Easel")
        #expect(host.published.layers.last?.name == "Easel")
    }

    @Test func viewportMapsCanvasPointsBothWays() {
        let viewport = CanvasViewport(
            canvasSize: CGSize(width: 200, height: 100), viewportSize: CGSize(width: 432, height: 332),
            insets: .init(), zoom: 2, pan: CGSize(width: 10, height: -5)
        )
        let point = CGPoint(x: 37, y: 81)
        let back = viewport.canvasPoint(viewport.screenPoint(point))
        #expect(abs(back.x - point.x) < 0.0001 && abs(back.y - point.y) < 0.0001)
        #expect(viewport.scale == 4)
    }

    @Test func aTurnedViewportMapsCanvasPointsBothWays() {
        let viewport = CanvasViewport(
            canvasSize: CGSize(width: 200, height: 100), viewportSize: CGSize(width: 432, height: 332),
            insets: .init(top: 8, leading: 72, bottom: 64, trailing: 0), zoom: 2, pan: CGSize(width: 10, height: -5),
            rotation: 0.7
        )
        let point = CGPoint(x: 37, y: 81)
        let back = viewport.canvasPoint(viewport.screenPoint(point))
        #expect(abs(back.x - point.x) < 0.0001 && abs(back.y - point.y) < 0.0001)
        // Drawn level and turned about the view's middle, the canvas lands
        // where the turned viewport puts it.
        let level = viewport.level
        let offset = CGPoint(
            x: (level.viewportSize.width - viewport.viewportSize.width) / 2,
            y: (level.viewportSize.height - viewport.viewportSize.height) / 2
        )
        let drawn = level.screenPoint(point)
        let turned = CGPoint(x: drawn.x - offset.x - viewport.center.x, y: drawn.y - offset.y - viewport.center.y)
            .applying(CGAffineTransform(rotationAngle: viewport.rotation))
        let expected = viewport.screenPoint(point)
        #expect(abs(turned.x + viewport.center.x - expected.x) < 0.0001)
        #expect(abs(turned.y + viewport.center.y - expected.y) < 0.0001)
    }

    @Test func turningKeepsThePointUnderTheFingers() {
        let host = Host(.blank(size: CGSize(width: 200, height: 100)))
        host.state.viewportSize = CGSize(width: 400, height: 300)
        let anchor = CGPoint(x: 120, y: 90)
        let under = host.state.viewport.canvasPoint(anchor)
        host.state.rotate(by: 0.5, around: anchor)
        host.state.zoom(by: 1.5, around: anchor)
        host.state.pan(by: CGSize(width: 20, height: -10))
        let moved = CGPoint(x: anchor.x + 20, y: anchor.y - 10)
        let now = host.state.viewport.screenPoint(under)
        #expect(abs(now.x - moved.x) < 0.0001 && abs(now.y - moved.y) < 0.0001)
    }

    @Test func aTurnEndingNearAQuarterTurnSettlesOnIt() {
        let host = Host(.blank(size: CGSize(width: 200, height: 100)))
        host.state.viewportSize = CGSize(width: 400, height: 300)
        host.state.rotate(by: .pi / 2 + 0.05, around: CGPoint(x: 50, y: 50))
        host.state.settleRotation()
        #expect(abs(host.state.rotation - .pi / 2) < 0.0001)
        host.state.rotate(by: 0.5, around: CGPoint(x: 50, y: 50))
        host.state.settleRotation()
        #expect(abs(host.state.rotation - (.pi / 2 + 0.5)) < 0.0001)
        host.state.fitCanvas()
        #expect(host.state.rotation == 0)
    }
}

@Suite("Undo")
struct EditScopeTests {
    @Test func sliderDragsOnOneLayerCoalesce() {
        var before = Composition.blank(size: CGSize(width: 4, height: 4))
        before.layers[0].opacity = 0.9
        var after = before
        after.layers[0].opacity = 0.5
        let scope = EditScope(from: before, to: after)
        #expect(scope.kind == .opacity)
        #expect(scope.coalesces)
    }

    @Test func structuralChangesAreStepsOfTheirOwn() {
        let before = Composition.blank(size: CGSize(width: 4, height: 4))
        var after = before
        after.layers.append(before.emptyLayer())
        #expect(!EditScope(from: before, to: after).coalesces)
    }
}

@MainActor
@Suite("Text tool")
struct TextToolTests {
    @Test func tapsOffThePictureAddNoText() {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 100, height: 100))) { _ in }
        state.tool = .text
        state.toolEnded(isTap: true, at: CGPoint(x: 50, y: 400))
        #expect(state.composition.layers.count == 1)
        #expect(state.presentedPanel == nil)
    }
}
