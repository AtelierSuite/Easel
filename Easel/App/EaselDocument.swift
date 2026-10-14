import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Easel's own layered document, declared in Info.plist.
    static let easelImage = UTType(exportedAs: "com.tsubuzaki.Easel.image", conformingTo: .package)
    /// Photoshop documents, declared by the system.
    static let photoshopImage = UTType("com.adobe.photoshop-image") ?? UTType(importedAs: "com.adobe.photoshop-image")
    /// Large Photoshop documents (`.psb`), declared by the system.
    static let photoshopLargeImage = UTType("com.adobe.photoshop-large-image")
        ?? UTType(importedAs: "com.adobe.photoshop-large-image")
    /// Pixelmator Pro documents saved as a single ZIP file, declared in Info.plist.
    static let pixelmatorProImage = UTType(importedAs: "com.pixelmatorteam.pixelmator.document.binary")
    /// Pixelmator Pro documents saved as a package folder, declared in Info.plist.
    static let pixelmatorProPackage = UTType(importedAs: "com.pixelmatorteam.pixelmator.document.package")
}

/// The app's document: a layered composition, kept as an `.easel` package,
/// or a plain picture file edited where it lies — which keeps its format
/// and so is flattened when it is saved.
struct EaselDocument: FileDocument {
    /// Photoshop and Pixelmator Pro files open, but are saved as an Easel
    /// copy before they are edited. Photoshop files, large ones too, can
    /// still be written; Pixelmator Pro files cannot.
    static let readableContentTypes: [UTType] = [
        .easelImage, .png, .jpeg, .heic, .photoshopImage, .photoshopLargeImage,
        .pixelmatorProImage, .pixelmatorProPackage,
    ]
    static let writableContentTypes: [UTType] = [.easelImage, .png, .jpeg, .heic, .photoshopImage, .photoshopLargeImage]

    var composition: Composition

    init() {
        composition = .blank()
    }

    init(composition: Composition) {
        self.composition = composition
    }

    init(configuration: ReadConfiguration) throws {
        composition = try Self.composition(from: configuration.file, contentType: configuration.contentType)
    }

    static func composition(from file: FileWrapper, contentType: UTType) throws -> Composition {
        // Earlier builds saved Easel packages over Pixelmator files, keeping
        // their names; those open as the Easel images they now are.
        let isPixelmator = contentType.conforms(to: .pixelmatorProImage) || contentType.conforms(to: .pixelmatorProPackage)
        if isPixelmator, !(file.isDirectory && file.fileWrappers?["metadata.info"] == nil) {
            return try PXDReader.composition(from: file)
        } else if file.isDirectory {
            return try CompositionArchive.composition(from: file)
        } else if contentType.conforms(to: .photoshopImage) || contentType.conforms(to: .photoshopLargeImage) {
            guard let data = file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return try PSDReader.composition(from: data)
        } else {
            guard let data = file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return Composition(image: try ImageCodec.decode(data), name: String(localized: "Layer.DefaultName.Background"))
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Saving still comes through for files Easel cannot write; they are
        // left exactly as they were.
        if Self.isReadOnly(configuration.contentType) {
            guard let existing = configuration.existingFile else { throw CocoaError(.fileWriteNoPermission) }
            return existing
        }
        if configuration.contentType.conforms(to: .photoshopLargeImage) {
            return FileWrapper(regularFileWithContents: try PSDWriter.data(for: composition, large: true))
        }
        if configuration.contentType.conforms(to: .photoshopImage) {
            return FileWrapper(regularFileWithContents: try PSDWriter.data(for: composition))
        }
        // Only a picture format named outright is flattened; anything else,
        // including a type the system has not resolved yet, keeps the layers.
        guard let type = Self.pictureType(for: configuration.contentType) else {
            return try CompositionArchive.fileWrapper(for: composition)
        }
        let image = CompositionRenderer.render(composition)
        return FileWrapper(regularFileWithContents: try ImageCodec.encode(image, as: type))
    }

    /// Types Easel opens but cannot write back.
    static func isReadOnly(_ contentType: UTType) -> Bool {
        [UTType.pixelmatorProImage, .pixelmatorProPackage].contains { contentType.conforms(to: $0) }
    }

    private static func pictureType(for contentType: UTType) -> UTType? {
        [UTType.png, .heic, .jpeg].first { contentType.conforms(to: $0) }
    }
}
