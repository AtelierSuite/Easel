import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@MainActor
@Suite("History steps")
struct HistoryStepTests {
    private func host() -> (EditorState, CompositionHistory, () -> Composition) {
        let state = EditorState()
        let history = CompositionHistory()
        let start = Composition.blank(size: CGSize(width: 10, height: 10))
        nonisolated(unsafe) var published = start
        state.attach(to: start) { published = $0 }
        state.edited = { history.record(from: $0, to: $1, tool: state.tool) }
        history.attach(to: nil, read: { state.read() }, write: { state.write($0) }, restored: { state.showRestored($0) })
        return (state, history, { published })
    }

    /// Lets the run loop turn, closing the undo group, as between taps.
    private func nextEvent() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func eachStepIsNamedAfterWhatItDid() async throws {
        let (state, history, _) = host()
        state.addEmptyLayer()
        try await nextEvent()
        state.updateActiveLayer { $0.opacity = 0.5 }
        try await nextEvent()
        state.addGuide(.vertical, at: 5)
        #expect(history.steps == [
            String(localized: "History.Opened"), String(localized: "History.AddLayer"),
            String(localized: "History.Opacity"), String(localized: "History.Guides"),
        ])
        #expect(history.position == 3)
    }

    @Test func changesInOneEventAreOneStep() {
        let (state, history, published) = host()
        state.addEmptyLayer()
        state.addEmptyLayer()
        #expect(history.steps.count == 2)
        history.undo()
        #expect(history.position == 0)
        #expect(published().layers.count == 1)
    }

    @Test func jumpingBackAndForthUndoesAndRedoes() async throws {
        let (state, history, published) = host()
        state.addEmptyLayer()
        try await nextEvent()
        state.addEmptyLayer()
        try await nextEvent()
        #expect(published().layers.count == 3)
        history.jump(to: 0)
        #expect(history.position == 0)
        #expect(published().layers.count == 1)
        history.jump(to: 2)
        #expect(published().layers.count == 3)
        history.jump(to: 1)
        // A new step drops the ones that could have been redone.
        state.addGuide(.horizontal, at: 3)
        #expect(history.steps.count == 3)
        #expect(history.position == 2)
        #expect(!history.canRedo)
    }

    @Test func theOriginalIsKeptToCompareAgainst() {
        let (state, history, _) = host()
        let original = state.read()
        state.addEmptyLayer()
        #expect(history.original == original)
    }

    @Test func aPaintedChangeIsNamedAfterTheTool() {
        let old = Composition.blank(size: CGSize(width: 4, height: 4))
        var new = old
        new.layers[0].image = LayerImage(TestImages.solid(.black, width: 4, height: 4))
        #expect(HistoryNaming.name(from: old, to: new, tool: .eraser) == String(localized: "Tool.Eraser"))
        #expect(HistoryNaming.name(from: old, to: new, tool: .move) == String(localized: "History.EditPixels"))
    }
}
