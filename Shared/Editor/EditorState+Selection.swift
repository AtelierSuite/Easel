import SwiftUI

extension EditorState {
    /// Takes a newly made selection in, the way the selection mode says.
    func select(_ new: Selection) {
        guard let current = selection, selectionMode != .replace else {
            selection = new
            return
        }
        let mode = selectionMode
        let size = composition.size
        replaceSelection { current.combined(with: new, mode: mode, canvasSize: size) }
    }

    /// Works a new selection out off the main thread; nil lets go of it.
    private func replaceSelection(_ work: @escaping @Sendable () -> Selection?) {
        enqueue({ PickedSelection(selection: work()) }, apply: { [weak self] picked in
            self?.selection = picked.selection
        })
    }

}

/// A selection worked out off the main thread, or nothing left selected.
private struct PickedSelection: Sendable {
    var selection: Selection?
}
