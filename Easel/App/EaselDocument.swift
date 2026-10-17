import Paintbrush
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
    /// Every type Easel opens it can also write back. Photoshop and
    /// Pixelmator Pro files are edited where they lie, written back into
    /// themselves, unless their reader found something that would be lost;
    /// then they are saved as an Easel copy before they are edited.
    static let readableContentTypes: [UTType] = [
        .easelImage, .png, .jpeg, .heic, .photoshopImage, .photoshopLargeImage,
        .pixelmatorProImage, .pixelmatorProPackage,
    ]
    static let writableContentTypes: [UTType] = [
        .easelImage, .png, .jpeg, .heic, .photoshopImage, .photoshopLargeImage,
        .pixelmatorProImage, .pixelmatorProPackage,
    ]

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
        if isPixelmator(contentType), !(file.isDirectory && file.fileWrappers?[PXDFormat.databaseName] == nil) {
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
        try written(as: configuration.contentType, existing: configuration.existingFile)
    }

    /// The document as a file of this type, given the file it is saved over.
    func written(as contentType: UTType, existing: FileWrapper?) throws -> FileWrapper {
        // A Photoshop or Pixelmator Pro file that would lose something is
        // left exactly as it was until it has been saved as a copy.
        if composition.needsCopyBeforeEditing, Self.isLayeredDocument(contentType), let existing {
            return existing
        }
        if contentType.conforms(to: .photoshopLargeImage) {
            return FileWrapper(regularFileWithContents: try PSDWriter.data(for: composition, large: true))
        }
        if contentType.conforms(to: .photoshopImage) {
            return FileWrapper(regularFileWithContents: try PSDWriter.data(for: composition))
        }
        if Self.isPixelmator(contentType) {
            return try pixelmatorFileWrapper(existing: existing)
        }
        // Only a picture format named outright is flattened; anything else,
        // including a type the system has not resolved yet, keeps the layers.
        guard let type = Self.pictureType(for: contentType) else {
            return try CompositionArchive.fileWrapper(for: composition)
        }
        let image = CompositionRenderer.render(composition)
        return FileWrapper(regularFileWithContents: try ImageCodec.encode(image, as: type))
    }

    /// A Pixelmator Pro document is written by patching the file it was read
    /// from, so there has to be one.
    private func pixelmatorFileWrapper(existing: FileWrapper?) throws -> FileWrapper {
        guard let existing else { throw CocoaError(.fileWriteUnsupportedScheme) }
        // An Easel package an earlier build saved under the Pixelmator name
        // stays one.
        if existing.isDirectory, existing.fileWrappers?[PXDFormat.databaseName] == nil {
            return try CompositionArchive.fileWrapper(for: composition)
        }
        return try PXDWriter.fileWrapper(for: composition, original: existing)
    }

    static func isPixelmator(_ contentType: UTType) -> Bool {
        contentType.conforms(to: .pixelmatorProImage) || contentType.conforms(to: .pixelmatorProPackage)
    }

    /// Photoshop and Pixelmator Pro documents, which Easel writes back into
    /// rather than replaces.
    static func isLayeredDocument(_ contentType: UTType) -> Bool {
        isPixelmator(contentType) || contentType.conforms(to: .photoshopImage)
            || contentType.conforms(to: .photoshopLargeImage)
    }

    private static func pictureType(for contentType: UTType) -> UTType? {
        [UTType.png, .heic, .jpeg].first { contentType.conforms(to: $0) }
    }
}
