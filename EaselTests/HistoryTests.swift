import CoreGraphics
import Testing
@testable import Easel
@testable import Paintbrush

@MainActor
@Suite("History")
struct HistoryTests {
    @Test func aDragIsOneUndoStep() {
        let state = EditorState()
        let history = CompositionHistory()
        let start = Composition.blank(size: CGSize(width: 10, height: 10))
        var published = start
        state.attach(to: start) { published = $0 }
        state.edited = { history.record(from: $0, to: $1) }
        history.attach(to: nil, read: { state.read() }, write: { state.write($0) }, restored: { state.showRestored($0) })

        state.tool = .move
        state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        for step in 2...10 {
            state.toolMoved(to: [StrokePoint(location: CGPoint(x: Double(step), y: 1))])
        }
        state.toolEnded(isTap: false, at: CGPoint(x: 10, y: 1))
        #expect(published.layers[0].transform.position.x == 14)

        history.undo()
        #expect(published.layers[0].transform.position == start.layers[0].transform.position)
    }

    @Test func undoingATurnPutsTheSelectionBackWithIt() {
        let state = EditorState()
        let history = CompositionHistory()
        state.attach(to: Composition.blank(size: CGSize(width: 40, height: 20))) { _ in }
        state.edited = { history.record(from: $0, to: $1) }
        history.attach(to: nil, read: { state.read() }, write: { state.write($0) }, restored: { state.showRestored($0) })
        let selected = Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 5)))
        state.selection = selected
        state.rotateCanvas(clockwise: true)
        let turned = state.selection
        #expect(turned != selected)
        history.undo()
        #expect(state.composition.size == CGSize(width: 40, height: 20))
        #expect(state.selection == selected)
        history.redo()
        #expect(state.selection == turned)
    }

    @Test func aGroupDragCoalescesLikeALayerDrag() {
        var before = Composition.blank(size: CGSize(width: 10, height: 10))
        before.layers.append(before.emptyLayer())
        var after = before
        for index in after.layers.indices { after.layers[index].transform.position.x += 3 }
        let scope = EditScope(from: before, to: after)
        #expect(scope.kind == .transform)
        #expect(scope.coalesces)
        // Anything besides placement is a step of its own.
        after.layers[1].opacity = 0.5
        #expect(!EditScope(from: before, to: after).coalesces)
    }
}

@MainActor
@Suite("Host echoes")
struct HostEchoTests {
    @Test func aLateEchoOfAnOlderEditIsIgnoredAndCorrected() {
        let state = EditorState()
        var published = Composition.blank(size: CGSize(width: 10, height: 10))
        state.attach(to: published) { published = $0 }
        state.updateActiveLayer { $0.opacity = 0.5 }
        let middle = state.composition
        state.updateActiveLayer { $0.opacity = 0.2 }
        // The document is stepped back behind the editor's back.
        published = middle
        state.sync(middle)
        #expect(state.composition.layers[0].opacity == 0.2)
        #expect(published.layers[0].opacity == 0.2)
    }

    @Test func aChangeFromTheHostIsTakenIn() {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 10, height: 10))) { _ in }
        var reverted = Composition.blank(size: CGSize(width: 20, height: 20))
        reverted.layers[0].name = "Reverted"
        state.sync(reverted)
        #expect(state.composition.layers[0].name == "Reverted")
    }
}
