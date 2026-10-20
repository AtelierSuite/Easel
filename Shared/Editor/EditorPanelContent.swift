import Paintbrush
import SwiftUI

/// What each panel shows, wherever it is presented: a sheet on iPhone, the
/// inspector on iPad and Mac.
struct EditorPanelContent: View {
    let panel: EditorPanel
    let state: EditorState
    let history: CompositionHistory

    var body: some View {
        switch panel {
        case .layers: LayersPanel(composition: state.composition, state: state)
        case .adjustments: AdjustmentsPanel(state: state)
        case .filters: LayerFiltersPanel(state: state)
        case .effects: LayerEffectsPanel(state: state)
        case .looks: LooksPanel(state: state)
        case .text: TextPanel(state: state)
        case .imageSize: CanvasSizePanel(state: state)
        case .history: HistoryPanel(history: history, state: state)
        case .comps: LayerCompsPanel(state: state)
        case .artboards: ArtboardsPanel(state: state)
        }
    }
}
