import Paintbrush
import SwiftUI

extension EditorState {
    /// Saves the layers as they are now as a new comp.
    func addLayerComp() {
        update { composition in
            composition.layerComps.append(composition.layerComp(named: composition.nextLayerCompName()))
        }
    }

    /// Puts a comp's arrangement back on the layers.
    func applyLayerComp(_ id: LayerComp.ID) {
        guard let comp = read().layerComps.first(where: { $0.id == id }) else { return }
        update { $0 = $0.applying(comp) }
    }

    /// Saves the layers as they are now over an existing comp.
    func updateLayerComp(_ id: LayerComp.ID) {
        update { composition in
            guard let index = composition.layerComps.firstIndex(where: { $0.id == id }) else { return }
            var comp = composition.layerComp(named: composition.layerComps[index].name)
            comp.id = id
            composition.layerComps[index] = comp
        }
    }

    func renameLayerComp(_ id: LayerComp.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { composition in
            guard let index = composition.layerComps.firstIndex(where: { $0.id == id }) else { return }
            composition.layerComps[index].name = trimmed
        }
    }

    func deleteLayerComp(_ id: LayerComp.ID) {
        update { $0.layerComps.removeAll { $0.id == id } }
    }

    /// Every comp drawn out as a picture of its own, as PNG files to share.
    nonisolated static func exportLayerComps(of composition: Composition) throws -> [URL] {
        try ImageFiles.write(composition.layerComps.map { comp in
            (comp.name, CompositionRenderer.render(composition.applying(comp)))
        })
    }
}

/// The picture's layer comps: saved arrangements of its layers, applied by
/// a tap, and exported each as a picture of its own.
struct LayerCompsPanel: View {
    @Bindable var state: EditorState
    @State private var renaming: LayerComp?
    @State private var newName = ""
    @State private var files: [URL] = []
    @State private var isExporting = false

    var body: some View {
        let comps = state.composition.layerComps
        List {
            Section {
                ForEach(comps) { comp in
                    Button {
                        state.applyLayerComp(comp.id)
                    } label: {
                        Label(comp.name, systemImage: "square.stack.3d.forward.dottedline")
                    }
                    .tint(.primary)
                    .contextMenu {
                        Button("Comps.Update", systemImage: "arrow.triangle.2.circlepath") { state.updateLayerComp(comp.id) }
                        Button("Layers.Rename", systemImage: "pencil") {
                            newName = comp.name
                            renaming = comp
                        }
                        Button("Layers.Delete", systemImage: "trash", role: .destructive) { state.deleteLayerComp(comp.id) }
                    }
                    .swipeActions {
                        Button("Layers.Delete", systemImage: "trash", role: .destructive) { state.deleteLayerComp(comp.id) }
                        Button("Comps.Update", systemImage: "arrow.triangle.2.circlepath") { state.updateLayerComp(comp.id) }
                            .tint(.indigo)
                    }
                    .accessibilityIdentifier("comp.\(comp.name)")
                }
                Button("Comps.Add", systemImage: "plus") {
                    state.addLayerComp()
                    files = []
                }
                .accessibilityIdentifier("addComp")
            } footer: {
                Text("Comps.Footer")
                    .panelFootnote()
            }
            if !comps.isEmpty {
                Section {
                    if files.isEmpty {
                        Button {
                            export()
                        } label: {
                            HStack {
                                Label("Comps.Export", systemImage: "square.and.arrow.up.on.square")
                                if isExporting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityIdentifier("exportComps")
                    } else {
                        ShareLink(items: files) {
                            Label(String(localized: "ExportPreset.Share \(files.count)"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .onChange(of: state.composition.layerComps) { _, _ in files = [] }
        .alert("Comps.Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Layers.Rename.Placeholder", text: $newName)
            Button("Common.Cancel", role: .cancel) { renaming = nil }
            Button("Layers.Rename.Confirm") {
                if let renaming { state.renameLayerComp(renaming.id, to: newName) }
                renaming = nil
            }
        }
        .panelActions(confirm: { state.presentedPanel = nil })
    }

    private func export() {
        let composition = state.composition
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                files = try await Task.detached(priority: .userInitiated) {
                    try EditorState.exportLayerComps(of: composition)
                }.value
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }
}
