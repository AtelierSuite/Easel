import Paintbrush
import SwiftUI

extension EditorState {
    /// Adds an artboard covering the selection, the crop frame, or else the
    /// whole canvas.
    func addArtboard() {
        let canvas = read().canvasRect
        var rect = canvas
        if let selection {
            rect = selection.bounds(in: canvas.size)
        } else if tool == .crop, let cropRect {
            rect = cropRect
        }
        rect = rect.integral.intersection(canvas)
        guard rect.width >= 1, rect.height >= 1 else { return }
        update { composition in
            composition.artboards.append(Artboard(name: composition.nextArtboardName(), rect: rect))
        }
    }

    func renameArtboard(_ id: Artboard.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { composition in
            guard let index = composition.artboards.firstIndex(where: { $0.id == id }) else { return }
            composition.artboards[index].name = trimmed
        }
    }

    func deleteArtboard(_ id: Artboard.ID) {
        update { $0.artboards.removeAll { $0.id == id } }
    }

    /// Every artboard drawn out as a picture of its own, as PNG files.
    nonisolated static func exportArtboards(of composition: Composition) throws -> [URL] {
        try ImageFiles.write(composition.artboards.map { ($0.name, composition.render($0)) })
    }
}

/// The picture's artboards: parts of the canvas, each exported as a
/// picture of its own.
struct ArtboardsPanel: View {
    @Bindable var state: EditorState
    @State private var renaming: Artboard?
    @State private var newName = ""
    @State private var files: [URL] = []
    @State private var isExporting = false

    var body: some View {
        let artboards = state.composition.artboards
        List {
            Section {
                ForEach(artboards) { artboard in
                    LabeledContent {
                        Text(verbatim: "\(Int(artboard.rect.width)) × \(Int(artboard.rect.height))")
                            .monospacedDigit()
                    } label: {
                        Label(artboard.name, systemImage: "rectangle.dashed")
                    }
                    .contextMenu {
                        Button("Layers.Rename", systemImage: "pencil") {
                            newName = artboard.name
                            renaming = artboard
                        }
                        Button("Layers.Delete", systemImage: "trash", role: .destructive) { state.deleteArtboard(artboard.id) }
                    }
                    .swipeActions {
                        Button("Layers.Delete", systemImage: "trash", role: .destructive) { state.deleteArtboard(artboard.id) }
                    }
                    .accessibilityIdentifier("artboard.\(artboard.name)")
                }
                Button("Artboards.Add", systemImage: "plus") { state.addArtboard() }
                    .accessibilityIdentifier("addArtboard")
            } footer: {
                Text("Artboards.Footer")
            }
            if !artboards.isEmpty {
                Section {
                    if files.isEmpty {
                        Button {
                            export()
                        } label: {
                            HStack {
                                Label("Artboards.Export", systemImage: "square.and.arrow.up.on.square")
                                if isExporting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityIdentifier("exportArtboards")
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
        .onChange(of: state.composition) { _, _ in files = [] }
        .alert("Artboards.Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Layers.Rename.Placeholder", text: $newName)
            Button("Common.Cancel", role: .cancel) { renaming = nil }
            Button("Layers.Rename.Confirm") {
                if let renaming { state.renameArtboard(renaming.id, to: newName) }
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
                    try EditorState.exportArtboards(of: composition)
                }.value
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }
}
