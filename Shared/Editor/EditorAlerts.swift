import Paintbrush
import SwiftUI

extension View {
    /// What went wrong, if anything, shown from this view while `isActive`.
    func errorAlert(_ state: EditorState, isActive: Bool) -> some View {
        alert(
            "Alert.Error.Title",
            isPresented: Binding(
                get: { isActive && state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("Common.OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    /// Asks, while an edit is held, whether to save the file as a copy and
    /// make the edit there, shown from this view while `isActive`.
    func copyBeforeEditingAlert(_ state: EditorState, isActive: Bool) -> some View {
        alert(
            "CopyToEasel.Title",
            isPresented: Binding(
                get: { isActive && state.isAskingToCopy },
                set: { if !$0 { state.isAskingToCopy = false } }
            )
        ) {
            Button("CopyToEasel.SaveAndEdit") { state.saveCopyForHeldEdit() }
            Button("CopyToEasel.CancelEdit", role: .cancel) { state.cancelHeldEdit() }
        } message: {
            // What would be lost, one to a line, after the explanation.
            let reasons = (state.copyBeforeEditing?.reasons ?? []).map { "• \($0)" }
            Text(verbatim: ([String(localized: "CopyToEasel.Message")] + (reasons.isEmpty ? [] : [reasons.joined(separator: "\n")]))
                .joined(separator: "\n\n"))
        }
    }
}

/// What the "…" menu's Unsupported Features item shows: the parts of a
/// Photoshop or Pixelmator Pro file that Easel cannot save back into it.
struct UnsupportedFeatureNotice: View {
    var losses: Set<WriteBackLoss>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Notice.UnsupportedFeatures.Title", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Text("Notice.UnsupportedFeatures.Message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(WriteBackLoss.allCases.filter(losses.contains), id: \.self) { loss in
                    Label(loss.label, systemImage: "minus")
                        .font(.callout)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}
