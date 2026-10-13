import CoreGraphics
import Foundation

/// The preview an Easel or Pixelmator Pro document keeps inside itself, for
/// showing it without opening it.
enum DocumentPreview {
    static let candidates = [
        "QuickLook/Thumbnail.png", "QuickLook/Thumbnail.webp", "QuickLook/Thumbnail.tiff", "QuickLook/Icon.webp",
    ]

    static func image(at url: URL) -> CGImage? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            for name in candidates {
                if let data = try? Data(contentsOf: url.appending(path: name)), let image = try? ImageCodec.decode(data) {
                    return image
                }
            }
            return nil
        }
        // A single-file package, as Pixelmator Pro saves by default: only
        // the preview is read out of it.
        guard let archive = try? ZipArchive.mappedFile(at: url) else { return nil }
        for name in candidates {
            if let data = try? ZipArchive.entry(named: name, in: archive), let image = try? ImageCodec.decode(data) {
                return image
            }
        }
        return nil
    }

    /// `size` scaled to fit within `bounds`, keeping its shape.
    static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
