import CoreGraphics
import Foundation

/// How a composition is kept on disk: a package holding a manifest and one
/// PNG per layer, plus a thumbnail for the file browser.
///
/// The same records, flattened into one blob, travel with a photo edited in
/// place so its layers come back the next time it is opened.
enum CompositionArchive {
    static let manifestName = "Manifest.json"
    static let layersFolderName = "Layers"
    static let thumbnailFolderName = "QuickLook"
    static let thumbnailName = "Thumbnail.png"
    static let currentVersion = 1
    /// Stands in for a layer file when the layer is the photo it was opened
    /// from, which the Photos library keeps already.
    static let originalImageMarker = "@original"

    enum Failure: LocalizedError {
        case missingManifest
        case newerVersion
        case missingLayer(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest, .missingLayer: return String(localized: "Error.DocumentDamaged")
            case .newerVersion: return String(localized: "Error.DocumentTooNew")
            }
        }
    }

    struct Manifest: Codable {
        var version: Int
        var width: Double
        var height: Double
        var layers: [LayerRecord]
        var groups: [LayerGroup]?
        var guides: [Guide]?
        var swatches: [RGBAColor]?
        var patterns: [PatternRecord]?
        var layerComps: [LayerComp]?
        var artboards: [Artboard]?
    }

    struct PatternRecord: Codable {
        var id: UUID
        var name: String
        var file: String
    }

    struct LayerRecord: Codable {
        var id: UUID
        var name: String
        var file: String
        var text: TextContent?
        var vector: VectorContent?
        var filters: [LayerFilter]?
        var effects: [LayerEffect]?
        var adjustment: LayerFilter?
        var maskFile: String?
        var maskEnabled: Bool?
        var transform: LayerTransform
        var opacity: Double
        var blendMode: LayerBlendMode
        var isClipped: Bool?
        var isVisible: Bool
        var isLocked: Bool
        var groupID: UUID?
        /// Whether the layer is still the plain fill a new document starts
        /// with; absent when it is not.
        var isBlank: Bool?
    }

    // MARK: - Package

    static func fileWrapper(for composition: Composition) throws -> FileWrapper {
        var files: [String: FileWrapper] = [:]
        let manifest = try manifest(for: composition, original: nil) { name, data in
            files[name] = FileWrapper(regularFileWithContents: data)
        }
        let layers = FileWrapper(directoryWithFileWrappers: files)
        layers.preferredFilename = layersFolderName

        let thumbnail = CompositionRenderer.thumbnail(composition, maxPixelSize: 512)
        let quickLook = FileWrapper(directoryWithFileWrappers: [
            thumbnailName: FileWrapper(regularFileWithContents: try ImageCodec.encode(thumbnail, as: .png)),
        ])
        quickLook.preferredFilename = thumbnailFolderName

        return FileWrapper(directoryWithFileWrappers: [
            manifestName: FileWrapper(regularFileWithContents: try encoder.encode(manifest)),
            layersFolderName: layers,
            thumbnailFolderName: quickLook,
        ])
    }

    static func composition(from wrapper: FileWrapper) throws -> Composition {
        guard let data = wrapper.fileWrappers?[manifestName]?.regularFileContents else { throw Failure.missingManifest }
        let files = wrapper.fileWrappers?[layersFolderName]?.fileWrappers ?? [:]
        return try composition(from: try JSONDecoder().decode(Manifest.self, from: data), original: nil) { name in
            files[name]?.regularFileContents
        }
    }

    // MARK: - Single blob

    private struct Blob: Codable {
        var manifest: Manifest
        var files: [String: Data]
    }

    /// The composition as one piece of data. A layer showing `original`
    /// untouched is recorded as a reference to it rather than copied.
    static func data(for composition: Composition, original: LayerImage?) throws -> Data {
        var files: [String: Data] = [:]
        let manifest = try manifest(for: composition, original: original) { files[$0] = $1 }
        return try PropertyListEncoder.binary.encode(Blob(manifest: manifest, files: files))
    }

    /// Reads back `data(for:original:)`, with `original` standing in for the
    /// layers that referred to it.
    static func composition(from data: Data, original: LayerImage?) throws -> Composition {
        let blob = try PropertyListDecoder().decode(Blob.self, from: data)
        return try composition(from: blob.manifest, original: original) { blob.files[$0] }
    }

    // MARK: - Shared

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static func manifest(
        for composition: Composition, original: LayerImage?, write: (String, Data) throws -> Void
    ) throws -> Manifest {
        var written: [ObjectIdentifier: String] = [:]
        var records: [LayerRecord] = []
        for layer in composition.layers {
            let file: String
            if let original, layer.image === original {
                file = originalImageMarker
            } else if let existing = written[ObjectIdentifier(layer.image)] {
                // Duplicated layers share their pixels until one is painted on.
                file = existing
            } else {
                file = "\(layer.id.uuidString).png"
                try write(file, try layer.image.pngData())
                written[ObjectIdentifier(layer.image)] = file
            }
            var maskFile: String?
            if let mask = layer.mask {
                let name = "\(layer.id.uuidString)-mask.png"
                try write(name, try mask.image.pngData())
                maskFile = name
            }
            records.append(LayerRecord(
                id: layer.id, name: layer.name, file: file, text: layer.text, vector: layer.vector,
                filters: layer.filters.isEmpty ? nil : layer.filters,
                effects: layer.effects.isEmpty ? nil : layer.effects,
                adjustment: layer.adjustment,
                maskFile: maskFile, maskEnabled: layer.mask.map(\.isEnabled), transform: layer.transform,
                opacity: layer.opacity, blendMode: layer.blendMode, isClipped: layer.isClipped ? true : nil,
                isVisible: layer.isVisible, isLocked: layer.isLocked,
                groupID: layer.groupID,
                isBlank: layer.image.isBlank ? true : nil
            ))
        }
        var patterns: [PatternRecord] = []
        for pattern in composition.patterns {
            let file = "pattern-\(pattern.id.uuidString).png"
            try write(file, try pattern.image.pngData())
            patterns.append(PatternRecord(id: pattern.id, name: pattern.name, file: file))
        }
        return Manifest(
            version: currentVersion, width: composition.size.width, height: composition.size.height, layers: records,
            groups: composition.groups.isEmpty ? nil : composition.groups,
            guides: composition.guides.isEmpty ? nil : composition.guides,
            swatches: composition.swatches.isEmpty ? nil : composition.swatches,
            patterns: patterns.isEmpty ? nil : patterns,
            layerComps: composition.layerComps.isEmpty ? nil : composition.layerComps,
            artboards: composition.artboards.isEmpty ? nil : composition.artboards
        )
    }

    private static func composition(
        from manifest: Manifest, original: LayerImage?, read: (String) -> Data?
    ) throws -> Composition {
        guard manifest.version <= currentVersion else { throw Failure.newerVersion }
        var images: [String: LayerImage] = [:]
        if let original { images[originalImageMarker] = original }
        let layers = try manifest.layers.map { record in
            let image: LayerImage
            if let loaded = images[record.file] {
                image = loaded
            } else {
                guard let data = read(record.file) else { throw Failure.missingLayer(record.file) }
                // Kept with its PNG, so saving again does not encode it again.
                image = LayerImage(try ImageCodec.decode(data), isBlank: record.isBlank ?? false, encoded: data)
                images[record.file] = image
            }
            var mask: LayerMask?
            if let maskFile = record.maskFile {
                guard let data = read(maskFile) else { throw Failure.missingLayer(maskFile) }
                mask = LayerMask(
                    image: LayerImage(try ImageCodec.decode(data), encoded: data), isEnabled: record.maskEnabled ?? true
                )
            }
            var layer = Layer(
                id: record.id, name: record.name, image: image, text: record.text, vector: record.vector,
                filters: record.filters ?? [], mask: mask, transform: record.transform,
                opacity: record.opacity, blendMode: record.blendMode, isVisible: record.isVisible,
                isLocked: record.isLocked
            )
            layer.groupID = record.groupID
            layer.isClipped = record.isClipped ?? false
            layer.effects = record.effects ?? []
            layer.adjustment = record.adjustment
            return layer
        }
        var composition = Composition(
            size: CGSize(width: manifest.width, height: manifest.height), layers: layers, groups: manifest.groups ?? []
        )
        composition.guides = manifest.guides ?? []
        composition.swatches = manifest.swatches ?? []
        composition.layerComps = manifest.layerComps ?? []
        composition.artboards = manifest.artboards ?? []
        composition.patterns = try (manifest.patterns ?? []).map { record in
            guard let data = read(record.file) else { throw Failure.missingLayer(record.file) }
            return PatternSwatch(id: record.id, name: record.name, image: LayerImage(try ImageCodec.decode(data), encoded: data))
        }
        composition.normalizeGroups()
        return composition
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
