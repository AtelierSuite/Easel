import Observation
import Paintbrush
import SwiftUI

/// One picture being edited: the editor's state and its undo history, tied
/// to whatever keeps the picture — a document, or a smart object's layer.
@MainActor
final class EditorSession {
    let state = EditorState()
    let history = CompositionHistory()
    /// Sheets the Mac's menus and toolbar bring up over the canvas.
    let sheets = EditorSheets()

    init(composition: Composition, publish: @escaping (Composition) -> Void) {
        state.attach(to: composition, publish: publish)
        state.edited = { [weak state, weak history] old, new in
            history?.record(from: old, to: new, tool: state?.tool)
        }
        // The editor's own undo manager, not the window's: text fields
        // register their typing with the window's, and those steps are not
        // the picture's.
        history.attach(
            to: nil,
            read: { [weak state] in state?.read() ?? composition },
            write: { [weak state] in state?.write($0) },
            restored: { [weak state] in state?.showRestored($0) }
        )
    }
}

/// What is showing over the canvas besides the editor's own alerts.
@MainActor
@Observable
final class EditorSheets {
    var isExportingWithPresets = false
    var isShowingUnsupportedFeatures = false
}

/// Runs `body` now and again whenever anything it read from an observable
/// object changes. Capture owners weakly: once `body` reads nothing, it
/// stops being run.
@MainActor
func observeChanges(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking(body) {
        Task { @MainActor in observeChanges(body) }
    }
}
