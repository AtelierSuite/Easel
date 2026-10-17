import CoreGraphics
import Foundation
import Observation
import Paintbrush
import SwiftUI

/// A way of exporting kept by name: a format, a quality, and the largest
/// the picture may be, as for the web or an app's store page.
struct ExportPreset: Codable, Hashable, Identifiable, Sendable {
    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case png, jpeg, heic

        var id: String { rawValue }

        var export: CompositionExport.Format {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }

        /// Whether the format has a quality to set.
        var isLossy: Bool { self != .png }
    }

    var id = UUID()
    var name: String
    var format: Format
    /// 0...1, for JPEG and HEIC.
    var quality = 0.85
    /// The picture is shrunk to fit within these, in pixels, and never
    /// enlarged; nil leaves that side free.
    var maxWidth: Int?
    var maxHeight: Int?

    /// The size a picture of `size` comes out at.
    func outputSize(for size: CGSize) -> CGSize {
        var factor = 1.0
        if let maxWidth { factor = min(factor, Double(maxWidth) / size.width) }
        if let maxHeight { factor = min(factor, Double(maxHeight) / size.height) }
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }

    /// "JPEG · 1600 × 1600 px · 85%", for showing under the name.
    var summary: String {
        var parts = [format.rawValue.uppercased()]
        switch (maxWidth, maxHeight) {
        case let (width?, height?): parts.append("\(width) × \(height) px")
        case let (width?, nil): parts.append(String(localized: "ExportPreset.Width \(width)"))
        case let (nil, height?): parts.append(String(localized: "ExportPreset.Height \(height)"))
        case (nil, nil): parts.append(String(localized: "ExportPreset.FullSize"))
        }
        if format.isLossy { parts.append("\(Int((quality * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    /// The presets that come with the app.
    static let builtIn: [ExportPreset] = [
        ExportPreset(name: String(localized: "ExportPreset.Web"), format: .jpeg, quality: 0.8, maxWidth: 1600, maxHeight: 1600),
        ExportPreset(name: String(localized: "ExportPreset.Thumbnail"), format: .jpeg, quality: 0.75, maxWidth: 400, maxHeight: 400),
        ExportPreset(name: String(localized: "ExportPreset.Social"), format: .jpeg, quality: 0.9, maxWidth: 1080, maxHeight: 1350),
        ExportPreset(name: String(localized: "ExportPreset.AppStore"), format: .png, maxWidth: 1320, maxHeight: 2868),
        ExportPreset(name: String(localized: "ExportPreset.FullPNG"), format: .png),
    ]
}

extension ExportPreset {
    /// The picture flattened, sized and written as this preset says.
    func data(for composition: Composition) throws -> Data {
        try data(forFlattened: CompositionRenderer.render(composition), size: composition.size)
    }

    /// The picture, already flattened at `size`, sized and written as this
    /// preset says, so several presets can share one flattening.
    func data(forFlattened image: CGImage, size original: CGSize) throws -> Data {
        let size = outputSize(for: original)
        let sized = size == original ? image : Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
        return try ImageCodec.encode(sized, as: format.export.contentType, quality: quality)
    }

    /// The file name for a picture called `name`, with the preset's name
    /// after it so a batch's files stay apart.
    func filename(for name: String) -> String {
        let clean = { (text: String) in
            text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stem = clean(name).isEmpty ? String(localized: "Export.DefaultName") : clean(name)
        return "\(stem) - \(clean(self.name)).\(format.export.pathExtension)"
    }

    /// Writes the picture once for each preset into a new folder, and
    /// returns the files.
    @concurrent
    static func export(_ composition: Composition, named name: String, with presets: [ExportPreset]) async throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        // Flattened once for all of them: the slow part.
        let image = CompositionRenderer.render(composition)
        for preset in presets {
            var url = folder.appending(path: preset.filename(for: name))
            // Two presets with the same name still make two files.
            var number = 2
            while urls.contains(url) {
                url = folder.appending(path: preset.filename(for: "\(name) \(number)"))
                number += 1
            }
            try preset.data(forFlattened: image, size: composition.size).write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}

/// The presets someone has made, kept between launches.
@MainActor
@Observable
final class ExportPresetLibrary {
    static let shared = ExportPresetLibrary(defaults: .standard)

    private(set) var saved: [ExportPreset]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "ExportPresets"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([ExportPreset].self, from: $0) } ?? []
    }

    var all: [ExportPreset] { ExportPreset.builtIn + saved }

    func save(_ preset: ExportPreset) {
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { return }
        saved.append(preset)
        persist()
    }

    func delete(_ preset: ExportPreset) {
        saved.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }
}

/// Exports the picture with several presets at once, then shares the files.
struct ExportPresetsSheet: View {
    let composition: Composition
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var library = ExportPresetLibrary.shared
    @State private var chosen: Set<ExportPreset.ID> = []
    @State private var files: [URL] = []
    @State private var isExporting = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(library.all) { preset in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(preset.id) },
                            set: { isOn in
                                if isOn { chosen.insert(preset.id) } else { chosen.remove(preset.id) }
                                files = []
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if library.saved.contains(preset) {
                                Button("ExportPreset.Delete", systemImage: "trash", role: .destructive) {
                                    chosen.remove(preset.id)
                                    library.delete(preset)
                                }
                            }
                        }
                    }
                    Button("ExportPreset.New", systemImage: "plus") { isAdding = true }
                } footer: {
                    Text("ExportPreset.Footer")
                }
                if !files.isEmpty {
                    Section {
                        ShareLink(items: files) {
                            Label(String(localized: "ExportPreset.Share \(files.count)"), systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("shareExports")
                    }
                }
            }
            .navigationTitle("ExportPreset.Title")
            .inlineNavigationTitle()
            // Presented over a document, which would otherwise lend it a
            // back button to the file browser.
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Common.Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("ExportPreset.Export") { export() }
                            .disabled(chosen.isEmpty)
                            .accessibilityIdentifier("exportWithPresets")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                NewExportPresetForm { library.save($0) }
                    .presentationContentInteraction(.scrolls)
            }
            .alert(
                "Alert.Error.Title",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("Common.OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func export() {
        let presets = library.all.filter { chosen.contains($0.id) }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                files = try await ExportPreset.export(composition, named: name, with: presets)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Makes a preset: its name, format, quality and largest size.
private struct NewExportPresetForm: View {
    let save: (ExportPreset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preset = ExportPreset(name: "", format: .jpeg)

    var body: some View {
        NavigationStack {
            Form {
                TextField("ExportPreset.Name", text: $preset.name)
                Picker("ExportPreset.Format", selection: $preset.format) {
                    ForEach(ExportPreset.Format.allCases) { format in
                        Text(format.export.label).tag(format)
                    }
                }
                if preset.format.isLossy {
                    LabeledSlider(
                        label: "ExportPreset.Quality", value: $preset.quality, range: 0.1...1,
                        valueText: "\(Int((preset.quality * 100).rounded()))%"
                    )
                }
                Section {
                    sideField("ExportPreset.MaxWidth", value: $preset.maxWidth)
                    sideField("ExportPreset.MaxHeight", value: $preset.maxHeight)
                } footer: {
                    Text("ExportPreset.SizeFooter")
                }
            }
            .navigationTitle("ExportPreset.New")
            .inlineNavigationTitle()
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Common.Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Brush.Save") {
                        save(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func sideField(_ label: LocalizedStringKey, value: Binding<Int?>) -> some View {
        LabeledContent(label) {
            TextField("ExportPreset.Any", value: value, format: .number)
                .numberKeyboard(.integer)
                .rowFieldLabelHidden()
                .multilineTextAlignment(.trailing)
        }
    }
}
