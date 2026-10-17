import CoreGraphics
import Foundation

/// How a composition is kept on disk: a package holding a manifest and one
/// PNG per layer, plus a thumbnail for the file browser.
///
/// The same records, flattened into one blob, travel with a photo edited in
/// place so its layers come back the next time it is opened.
package enum CompositionArchive {
    package static let manifestName = "Manifest.json"
    package static let layersFolderName = "Layers"
    package static let thumbnailFolderName = "QuickLook"
    package static let thumbnailName = "Thumbnail.png"
    package static let currentVersion = 1
    /// Stands in for a layer file when the layer is the photo it was opened
    /// from, which the Photos library keeps already.
    package static let originalImageMarker = "@original"

    package enum Failure: LocalizedError {
        case missingManifest
        case newerVersion
        case missingLayer(String)

        package var errorDescription: String? {
            switch self {
            case .missingManifest, .missingLayer: return String(localized: "Error.DocumentDamaged")
            case .newerVersion: return String(localized: "Error.DocumentTooNew")
            }
        }
    }

    package struct Manifest: Codable {
        package var version: Int
        package var width: Double
        package var height: Double
        package var layers: [LayerRecord]
        package var groups: [LayerGroup]?
        package var guides: [Guide]?
        package var swatches: [RGBAColor]?
        package var patterns: [PatternRecord]?
        package var layerComps: [LayerComp]?
        package var artboards: [Artboard]?
        package var resolution: Double?
    }

    package struct PatternRecord: Codable {
        package var id: UUID
        package var name: String
        package var file: String
    }

    package struct LayerRecord: Codable {
        package var id: UUID
        package var name: String
        package var file: String
        package var text: TextContent?
        package var vector: VectorContent?
        package var filters: [LayerFilter]?
        package var effects: [LayerEffect]?
        package var adjustment: LayerFilter?
        /// A smart object's contents, kept as a file of their own.
        package var smartFile: String?
        /// How a smart object's contents are bent.
        package var smartWarp: SmartObjectWarp?
        /// A linked file a Photoshop smart object is waiting for.
        package var missingLink: SmartObjectLink?
        package var maskFile: String?
        package var maskEnabled: Bool?
        /// The filter mask's pixels, and whether it is on.
        package var filterMaskFile: String?
        package var filterMaskEnabled: Bool?
        package var transform: LayerTransform
        package var opacity: Double
        /// Absent when full.
        package var fillOpacity: Double?
        package var blendMode: LayerBlendMode
        package var isClipped: Bool?
        package var isVisible: Bool
        package var isLocked: Bool
        package var groupID: UUID?
        /// Whether the layer is still the plain fill a new document starts
        /// with; absent when it is not.
        package var isBlank: Bool?
        /// The layer's identifier in the Pixelmator Pro document it came from.
        package var pixelmatorID: String?
    }

    // MARK: - Package

    package static func fileWrapper(for composition: Composition) throws -> FileWrapper {
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

    package static func composition(from wrapper: FileWrapper) throws -> Composition {
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
    package static func data(for composition: Composition, original: LayerImage?) throws -> Data {
        var files: [String: Data] = [:]
        let manifest = try manifest(for: composition, original: original) { files[$0] = $1 }
        return try PropertyListEncoder.binary.encode(Blob(manifest: manifest, files: files))
    }

    /// Reads back `data(for:original:)`, with `original` standing in for the
    /// layers that referred to it.
    package static func composition(from data: Data, original: LayerImage?) throws -> Composition {
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
            var smartFile: String?
            if let smart = layer.smartObject {
                let name = "\(layer.id.uuidString)-contents.plist"
                try write(name, try data(for: smart.contents, original: nil))
                smartFile = name
            }
            var maskFile: String?
            if let mask = layer.mask {
                let name = "\(layer.id.uuidString)-mask.png"
                try write(name, try mask.image.pngData())
                maskFile = name
            }
            var filterMaskFile: String?
            if let mask = layer.filterMask {
                let name = "\(layer.id.uuidString)-filtermask.png"
                try write(name, try mask.image.pngData())
                filterMaskFile = name
            }
            records.append(LayerRecord(
                id: layer.id, name: layer.name, file: file, text: layer.text, vector: layer.vector,
                filters: layer.filters.isEmpty ? nil : layer.filters,
                effects: layer.effects.isEmpty ? nil : layer.effects,
                adjustment: layer.adjustment,
                smartFile: smartFile, smartWarp: layer.smartObject?.warp, missingLink: layer.missingLink,
                maskFile: maskFile, maskEnabled: layer.mask.map(\.isEnabled),
                filterMaskFile: filterMaskFile, filterMaskEnabled: layer.filterMask.map(\.isEnabled), transform: layer.transform,
                opacity: layer.opacity, fillOpacity: layer.fillOpacity < 1 ? layer.fillOpacity : nil,
                blendMode: layer.blendMode, isClipped: layer.isClipped ? true : nil,
                isVisible: layer.isVisible, isLocked: layer.isLocked,
                groupID: layer.groupID,
                isBlank: layer.image.isBlank ? true : nil,
                pixelmatorID: layer.pixelmator.flatMap { $0.isPreview ? nil : $0.identifier }
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
            artboards: composition.artboards.isEmpty ? nil : composition.artboards,
            resolution: composition.resolution
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
            layer.fillOpacity = record.fillOpacity ?? 1
            layer.effects = record.effects ?? []
            layer.adjustment = record.adjustment
            layer.missingLink = record.missingLink
            layer.pixelmator = record.pixelmatorID.map { PixelmatorSource(identifier: $0) }
            if let file = record.filterMaskFile {
                guard let data = read(file) else { throw Failure.missingLayer(file) }
                layer.filterMask = LayerMask(
                    image: LayerImage(try ImageCodec.decode(data), encoded: data), isEnabled: record.filterMaskEnabled ?? true
                )
            }
            if let smartFile = record.smartFile {
                guard let data = read(smartFile) else { throw Failure.missingLayer(smartFile) }
                layer.smartObject = SmartObject(contents: try composition(from: data, original: nil), warp: record.smartWarp)
            }
            return layer
        }
        var composition = Composition(
            size: CGSize(width: manifest.width, height: manifest.height), layers: layers, groups: manifest.groups ?? []
        )
        composition.guides = manifest.guides ?? []
        composition.swatches = manifest.swatches ?? []
        composition.layerComps = manifest.layerComps ?? []
        composition.artboards = manifest.artboards ?? []
        composition.resolution = manifest.resolution
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
