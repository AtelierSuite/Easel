import SwiftUI

/// A document window: the editor, with sharing and the file's title menu.
struct DocumentView: View {
    @Binding var document: EaselDocument
    /// Where the file lives, which is what converting it moves.
    var fileURL: URL?
    @State private var errorMessage: String?
    @State private var savedToPhotos = false
    @State private var isExportingWithPresets = false
    @State private var isAskingToCopy = false
    @State private var isSavingCopy = false
    @State private var hasCopy = false
    @Environment(\.dismiss) private var dismiss

    private var name: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Export.DefaultName")
    }

    /// A Photoshop or Pixelmator Pro file, not yet saved as an Easel copy,
    /// which stays untouched until it is.
    private var requiresCopy: Bool {
        !hasCopy && fileURL.map(DocumentConversion.requiresCopy) == true
    }

    var body: some View {
        EditorView(composition: $document.composition) { exportMenu }
            .disabled(requiresCopy)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { titleMenu }
            .alert(
                "Alert.Error.Title",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("Common.OK", role: .cancel) {
                    errorMessage = nil
                    if requiresCopy { isAskingToCopy = true }
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("CopyToEasel.Title", isPresented: $isAskingToCopy) {
                Button("CopyToEasel.Save") { isSavingCopy = true }
                Button("CopyToEasel.Close", role: .cancel) { dismiss() }
            } message: {
                Text("CopyToEasel.Message")
            }
            .fileExporter(
                isPresented: $isSavingCopy, document: document, contentTypes: [.easelImage], defaultFilename: name
            ) { result in
                switch result {
                case .success(let url): adoptCopy(at: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            } onCancellation: {
                isAskingToCopy = true
            }
            .onAppear {
                if requiresCopy { isAskingToCopy = true }
            }
            .sensoryFeedback(.success, trigger: savedToPhotos)
            .sheet(isPresented: $isExportingWithPresets) {
                ExportPresetsSheet(composition: document.composition, name: name)
                    .presentationContentInteraction(.scrolls)
            }
    }

    /// Has the open document follow the copy just saved, so edits from here
    /// on are saved to it. The picker only grants access to the copy, so that
    /// access is held for as long as the app runs, through the document's
    /// last save as it closes.
    private func adoptCopy(at url: URL) {
        guard let fileURL else { return }
        _ = url.startAccessingSecurityScopedResource()
        Task {
            do {
                try await DocumentConversion.adopt(copyAt: url, of: fileURL)
                hasCopy = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Section("Export.ShareAs") {
                ForEach(CompositionExport.Format.allCases) { format in
                    ShareLink(
                        item: CompositionExport(composition: document.composition, name: name, format: format),
                        preview: SharePreview(name, image: Image(systemName: "photo"))
                    ) {
                        Text(format.label)
                    }
                }
            }
            Button("ExportPreset.Menu", systemImage: "square.stack.3d.down.right") {
                isExportingWithPresets = true
            }
            .accessibilityIdentifier("exportPresets")
            Button("Export.SaveToPhotos", systemImage: "photo.badge.plus") {
                let composition = document.composition
                Task {
                    do {
                        try await CompositionExport.saveToPhotos(composition)
                        savedToPhotos.toggle()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } label: {
            Label("Toolbar.Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("export")
    }

    /// Renaming, and — for a plain picture, which flattens when saved —
    /// turning the file into an Easel image that keeps its layers.
    @ViewBuilder
    private var titleMenu: some View {
        RenameButton()
        if let fileURL, DocumentConversion.canConvert(fileURL) {
            Section {
                Button("TitleMenu.ConvertToEasel", systemImage: "square.3.layers.3d") {
                    let composition = document.composition
                    Task {
                        do {
                            _ = try await DocumentConversion.convert(fileAt: fileURL, composition: composition)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } footer: {
                Text("TitleMenu.ConvertToEasel.Footer")
            }
        }
    }
}
