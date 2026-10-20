import Paintbrush
import QuickLookThumbnailing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Thumbnails for Easel and Pixelmator Pro documents in Files and the
/// Finder, drawn from the preview each keeps inside itself.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        guard let image = DocumentPreview.image(at: request.fileURL) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let size = DocumentPreview.fit(CGSize(width: image.width, height: image.height), in: request.maximumSize)
        handler(QLThumbnailReply(contextSize: size) {
            #if canImport(UIKit)
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            return true
            #else
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return true
            #endif
        }, nil)
    }
}
