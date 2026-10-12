import SwiftUI

/// A change to the whole selection that needs a size: how far to feather,
/// grow or shrink it, or how wide a band to refine along its edge.
enum SelectionEdit: Identifiable, Hashable, Sendable {
    case modify(SelectionModification)
    case refine

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .modify(let modification): return modification.label
        case .refine: return "Select.RefineEdge"
        }
    }

    var fieldLabel: LocalizedStringKey { "Select.Radius" }
}

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

    /// A size the edit starts from: a little of the picture.
    func defaultSize(for edit: SelectionEdit) -> Double {
        let longest = max(composition.size.width, composition.size.height)
        switch edit {
        case .refine: return max(4, (longest / 150).rounded())
        case .modify: return max(2, (longest / 200).rounded())
        }
    }

    /// Carries out a selection edit `size` canvas pixels big.
    func perform(_ edit: SelectionEdit, size: Double) {
        guard let selection else { return }
        let canvasSize = composition.size
        switch edit {
        case .modify(let modification):
            replaceSelection { selection.modified(modification, radius: size, canvasSize: canvasSize) }
        case .refine:
            let picture = CompositionRenderer.render(composition)
            replaceSelection { selection.refined(along: picture, radius: size) }
        }
    }
}

/// A selection worked out off the main thread, or nothing left selected.
private struct PickedSelection: Sendable {
    var selection: Selection?
}

extension View {
    /// Asks for the size of a pending selection edit, then carries it out.
    func selectionEditAlert(_ state: EditorState) -> some View {
        modifier(SelectionEditAlert(state: state))
    }
}

private struct SelectionEditAlert: ViewModifier {
    @Bindable var state: EditorState
    @State private var text = ""
    @State private var shown: SelectionEdit?

    func body(content: Content) -> some View {
        content
            .onChange(of: state.pendingSelectionEdit) { _, edit in
                guard let edit else { return }
                text = "\(Int(state.defaultSize(for: edit)))"
                shown = edit
            }
            .alert(
                shown?.title ?? "",
                isPresented: Binding(get: { shown != nil }, set: { if !$0 { close() } })
            ) {
                TextField(shown?.fieldLabel ?? "", text: $text)
                    .keyboardType(.decimalPad)
                Button("Common.Cancel", role: .cancel) { close() }
                Button("Common.OK") {
                    if let shown, let size = Double(text.replacingOccurrences(of: ",", with: ".")), size > 0 {
                        state.perform(shown, size: size)
                    }
                    close()
                }
            } message: {
                Text(shown?.fieldLabel ?? "")
            }
    }

    private func close() {
        shown = nil
        state.pendingSelectionEdit = nil
    }
}
