import Paintbrush
import SwiftUI

/// The middle of an editor window: the canvas, the settings of the tool in
/// hand floating along its bottom, and what the editor asks or warns about.
struct CanvasArea: View {
    @Bindable var state: EditorState
    let history: CompositionHistory
    @Bindable var sheets: EditorSheets
    /// The document's name, for exports.
    var name: () -> String

    var body: some View {
        // While comparing, the picture as it was opened, untouchable.
        CanvasView(
            composition: state.isComparing ? history.original ?? state.composition : state.composition,
            state: state, history: history
        )
        .allowsHitTesting(!state.isComparing)
        .background(Color.workspace)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                LinkedFilesBanner(state: state)
                ToolOptionsBar(state: state)
            }
            .canvasStatus(state)
            .padding(.bottom, 12)
        }
        .animation(.snappy(duration: 0.3), value: state.missingLinkNames + state.missingMapNames)
        .onAppear { state.canvasInsets = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8) }
        .errorAlert(state, isActive: true)
        .copyBeforeEditingAlert(state, isActive: true)
        .selectionEditAlert(state)
        .fileImporter(
            isPresented: $state.isImportingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let loaded = await ImageImport.load(urls)
                state.addImageLayers(loaded.images)
                if loaded.failed { state.errorMessage = String(localized: "Error.ImportFailed") }
            }
        }
        .dropDestination(for: DroppedImage.self) { items, _ in
            Task { state.addImageLayers(await ImageImport.load(items)) }
            return true
        }
        .sheet(isPresented: $sheets.isExportingWithPresets) {
            ExportPresetsSheet(composition: state.composition, name: name())
                .frame(minWidth: 420, minHeight: 460)
        }
        .sheet(isPresented: $sheets.isShowingUnsupportedFeatures) {
            UnsupportedFeatureNotice(losses: state.composition.writeBackLosses)
                .frame(minWidth: 400, minHeight: 280)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Common.OK") { sheets.isShowingUnsupportedFeatures = false }
                    }
                }
        }
    }
}
