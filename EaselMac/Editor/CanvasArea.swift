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
        .overlay { CanvasScrollers(state: state) }
        // Over the canvas rather than beside it, so the canvas still takes
        // the clicks either side of the bars; the picture fits above them.
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                LinkedFilesBanner(state: state)
                ToolOptionsBar(state: state)
            }
            .canvasStatus(state)
            .padding(.leading, state.canvasInsets.leading - 8)
            .padding(.bottom, CanvasViewController.margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                state.canvasInsets.bottom = height + 8
            }
        }
        .animation(.snappy(duration: 0.3), value: state.missingLinkNames + state.missingMapNames)
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
