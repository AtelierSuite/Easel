import Paintbrush
import SwiftUI

#if os(iOS)
/// A smart object's contents open in an editor of their own; Done puts them
/// back into the layer, drawn out afresh.
struct SmartObjectEditor: View {
    let state: EditorState
    let layerID: Layer.ID
    @State private var contents: Composition
    @State private var original: Composition
    @State private var isConfirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(state: EditorState, layerID: Layer.ID) {
        self.state = state
        self.layerID = layerID
        let contents = state.composition[layerID]?.smartObject?.contents ?? .blank()
        _contents = State(initialValue: contents)
        _original = State(initialValue: contents)
    }

    var body: some View {
        NavigationStack {
            EditorView(composition: $contents)
                .navigationTitle(state.composition[layerID]?.name ?? "")
                .inlineNavigationTitle()
                // Presented over a document, which would otherwise lend it a
                // back button to the file browser.
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) {
                            if contents != original { isConfirmingDiscard = true } else { dismiss() }
                        }
                        .confirmationDialog("SmartObject.Discard", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                            Button("PhotoEditor.Discard.Confirm", role: .destructive) { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Common.Done", systemImage: "checkmark", role: .confirm) {
                            if contents != original { state.updateSmartObject(layerID, contents: contents) }
                            dismiss()
                        }
                        .accessibilityIdentifier("finishSmartObject")
                    }
                }
        }
    }
}
#endif
