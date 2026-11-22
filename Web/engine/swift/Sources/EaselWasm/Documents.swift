import CoreGraphics
import Foundation
import Paintbrush

/// Reading and writing files, as EaselDocument does in the Apple apps.
enum Documents {
    /// A file's bytes, or a package folder zipped by the page.
    static func open(_ data: Data, name: String, isPackage: Bool) throws -> Composition {
        let lower = name.lowercased()
        if isPackage {
            let wrapper = try folder(fromZip: data)
            if wrapper.fileWrappers?[PXDFormat.databaseName] != nil { return try PXDReader.composition(from: wrapper) }
            return try CompositionArchive.composition(from: wrapper)
        }
        let bytes = [UInt8](data.prefix(4))
        if bytes == Array("8BPS".utf8) { return try PSDReader.composition(from: data) }
        if bytes.starts(with: [0x50, 0x4B]) {
            if lower.hasSuffix(".pxd") || (try? ZipArchive.entry(named: PXDFormat.databaseName, in: data)) != nil {
                return try PXDReader.composition(from: FileWrapper(regularFileWithContents: data))
            }
            // A zipped Easel package.
            let wrapper = try folder(fromZip: data)
            let root = wrapper.fileWrappers?.count == 1 && wrapper.fileWrappers?[CompositionArchive.manifestName] == nil
                ? wrapper.fileWrappers!.values.first! : wrapper
            return try CompositionArchive.composition(from: root)
        }
        let image = try ImageCodec.decode(data)
        return Composition(image: image, name: String(localized: "Layer.DefaultName.Background"))
    }

    /// A tree of files from a zip's entries.
    static func folder(fromZip data: Data) throws -> FileWrapper {
        let entries = try ZipArchive.entries(in: data)
        final class Node {
            var files: [String: Data] = [:]
            var folders: [String: Node] = [:]
            func wrapper() -> FileWrapper {
                var children: [String: FileWrapper] = [:]
                for (name, data) in files { children[name] = FileWrapper(regularFileWithContents: data) }
                for (name, node) in folders { children[name] = node.wrapper() }
                return FileWrapper(directoryWithFileWrappers: children)
            }
        }
        let root = Node()
        for (path, contents) in entries {
            var parts = path.split(separator: "/").map(String.init)
            guard let file = parts.popLast(), !file.isEmpty, !path.hasSuffix("/") else { continue }
            if parts.first == "__MACOSX" || file == ".DS_Store" { continue }
            var node = root
            for part in parts {
                if node.folders[part] == nil { node.folders[part] = Node() }
                node = node.folders[part]!
            }
            node.files[file] = contents
        }
        return root.wrapper()
    }

    static func export(_ composition: Composition, as format: String, quality: Double) throws -> Data {
        switch format {
        case "psd": return try PSDWriter.data(for: composition)
        case "psb": return try PSDWriter.data(for: composition, large: true)
        case "jpeg": return try ImageCodec.encode(CompositionRenderer.render(composition), as: .jpeg, quality: quality)
        case "svg": return SVGWriter.data(for: composition)
        case "easel":
            // A package can't be downloaded as a folder, so it goes as a zip of one.
            let wrapper = try CompositionArchive.fileWrapper(for: composition)
            var entries: [ZipArchive.Entry] = []
            func add(_ node: FileWrapper, path: String) {
                if let children = node.fileWrappers {
                    for (name, child) in children.sorted(by: { $0.key < $1.key }) { add(child, path: path.isEmpty ? name : "\(path)/\(name)") }
                } else if let contents = node.regularFileContents {
                    entries.append(ZipArchive.Entry(name: path, contents: contents, deflate: !path.hasSuffix(".png")))
                }
            }
            add(wrapper, path: "")
            return ZipArchive.archive(entries)
        default: return try ImageCodec.encode(CompositionRenderer.render(composition), as: .png)
        }
    }
}

enum Pixels {
    /// RGBA with straight alpha, as the page's ImageData wants it.
    static func straight(_ image: CGImage) -> Data {
        var rgba = image.rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = Int(rgba[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in i..<(i + 3) {
                let value: Int = (Int(rgba[c]) * 255 + a / 2) / a
                rgba[c] = UInt8(min(value, 255))
            }
        }
        return Data(rgba)
    }
}

enum Thumbnails {
    /// A layer as the Layers panel shows it: what it draws, within the canvas.
    static func image(of layer: Layer, in composition: Composition, size: Int) -> CGImage {
        var solo = layer
        solo.isVisible = true
        solo.opacity = 1
        solo.blendMode = .normal
        solo.groupID = nil
        solo.isClipped = false
        var single = composition
        single.layers = [solo]
        single.groups = []
        return CompositionRenderer.thumbnail(single, maxPixelSize: size)
    }
}

enum Edits {
    static func apply(_ request: [String: Any], to composition: inout Composition) {
        guard let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        if let index = composition.layers.firstIndex(where: { $0.id == id }) {
            var layer = composition.layers[index]
            if let visible = request["visible"] as? Bool { layer.isVisible = visible }
            if let opacity = request["opacity"] as? Double { layer.opacity = min(max(opacity, 0), 1) }
            if let mode = (request["blendMode"] as? String).flatMap(LayerBlendMode.init(rawValue:)) { layer.blendMode = mode }
            if let name = request["name"] as? String, !name.isEmpty { layer.name = name }
            if let locked = request["locked"] as? Bool { layer.isLocked = locked }
            if let fill = request["fillOpacity"] as? Double { layer.fillOpacity = min(max(fill, 0), 1) }
            if var adjustment = layer.adjustment {
                if let amount = request["amount"] as? Double {
                    adjustment.amount = min(max(amount, adjustment.kind.amountRange.lowerBound), adjustment.kind.amountRange.upperBound)
                }
                if let value = request["value"] as? Double, let at = request["parameter"] as? Int { adjustment.setValue(value, at: at) }
                if let enabled = request["adjustmentEnabled"] as? Bool { adjustment.isEnabled = enabled }
                layer.adjustment = adjustment
            }
            composition.layers[index] = layer
        } else if let index = composition.groups.firstIndex(where: { $0.id == id }) {
            var group = composition.groups[index]
            if let visible = request["visible"] as? Bool { group.isVisible = visible }
            if let opacity = request["opacity"] as? Double { group.opacity = min(max(opacity, 0), 1) }
            if let mode = request["blendMode"] as? String { group.blendMode = LayerBlendMode(rawValue: mode) }
            if let name = request["name"] as? String, !name.isEmpty { group.name = name }
            if let expanded = request["expanded"] as? Bool { group.isExpanded = expanded }
            if let locked = request["locked"] as? Bool { group.isLocked = locked }
            composition.groups[index] = group
        }
    }
}
