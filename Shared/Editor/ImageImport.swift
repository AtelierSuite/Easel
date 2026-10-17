import CoreGraphics
import CoreTransferable
import Paintbrush
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Brings pictures in from Photos, Files, drag and drop and the clipboard.
enum ImageImport {
    typealias Item = (image: CGImage, name: String)

    static func load(_ items: [PhotosPickerItem]) async -> (images: [Item], failed: Bool) {
        var images: [Item] = []
        var failed = false
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                failed = true
                continue
            }
            let decoded = await decode(data)
            if let decoded {
                images.append((decoded, String(localized: "Layer.DefaultName.Photo")))
            } else {
                failed = true
            }
        }
        return (images, failed)
    }

    /// Files picked in the document picker, which lie outside the sandbox
    /// until they are asked for.
    static func load(_ urls: [URL]) async -> (images: [Item], failed: Bool) {
        var images: [Item] = []
        var failed = false
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let image = await decode(data) else {
                failed = true
                continue
            }
            images.append((image, url.deletingPathExtension().lastPathComponent))
        }
        return (images, failed)
    }

    static func load(_ dropped: [DroppedImage]) async -> [Item] {
        var images: [Item] = []
        for item in dropped {
            if let image = await decode(item.data) {
                images.append((image, String(localized: "Layer.DefaultName.Image")))
            }
        }
        return images
    }

    /// Decoding a full-size photo takes long enough to keep off the main thread.
    @concurrent
    static func decode(_ data: Data) async -> CGImage? {
        try? ImageCodec.decode(data)
    }

    /// The picture on the clipboard, if there is one.
    @MainActor
    static func pasteboardImage() -> Item? {
        #if os(iOS)
        let pasteboard = UIPasteboard.general
        for type in [UTType.png, .heic, .jpeg, .tiff, .image] {
            if let data = pasteboard.data(forPasteboardType: type.identifier), let image = try? ImageCodec.decode(data) {
                return (image, String(localized: "Layer.DefaultName.Pasted"))
            }
        }
        if let image = pasteboard.image?.cgImage {
            return (ImageCodec.normalized(image), String(localized: "Layer.DefaultName.Pasted"))
        }
        #else
        let pasteboard = NSPasteboard.general
        for type in [UTType.png, .heic, .jpeg, .tiff, .image] {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)),
               let image = try? ImageCodec.decode(data) {
                return (image, String(localized: "Layer.DefaultName.Pasted"))
            }
        }
        if let image = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (ImageCodec.normalized(image), String(localized: "Layer.DefaultName.Pasted"))
        }
        #endif
        return nil
    }

    @MainActor
    static func copyToPasteboard(_ image: CGImage) {
        guard let data = try? ImageCodec.encode(image, as: .png) else { return }
        #if os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        #endif
    }
}

/// A picture dropped onto the canvas from another app.
struct DroppedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { DroppedImage(data: $0) }
    }
}
