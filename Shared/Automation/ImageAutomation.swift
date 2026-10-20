import CoreGraphics
import Foundation
import Paintbrush
import UniformTypeIdentifiers

/// What the Shortcuts actions do to pictures, kept apart from the actions
/// so it can be tested: read a file, change it, write it back out.
enum ImageAutomation {
    enum Failure: LocalizedError, Equatable {
        case noSize

        var errorDescription: String? {
            switch self {
            case .noSize: return String(localized: "Intent.Error.NoSize")
            }
        }
    }

    /// The picture in a file: an image, or a Photoshop document flattened.
    static func image(from data: Data, filename: String) throws -> CGImage {
        if ["psd", "psb"].contains((filename as NSString).pathExtension.lowercased()) {
            return CompositionRenderer.render(try PSDReader.composition(from: data))
        }
        return try ImageCodec.decode(data)
    }

    /// `image` at a new size. With only one side given, or with
    /// `keepsProportions`, the other follows the picture's proportions,
    /// fitting within both sides when both are given.
    static func resize(_ image: CGImage, width: Int?, height: Int?, keepsProportions: Bool = true) throws -> CGImage {
        let original = CGSize(width: image.width, height: image.height)
        let target: CGSize
        switch (width, height) {
        case (nil, nil):
            throw Failure.noSize
        case let (width?, nil):
            target = CGSize(width: Double(width), height: (Double(width) * original.height / original.width).rounded())
        case let (nil, height?):
            target = CGSize(width: (Double(height) * original.width / original.height).rounded(), height: Double(height))
        case let (width?, height?):
            if keepsProportions {
                let factor = min(Double(width) / original.width, Double(height) / original.height)
                target = CGSize(width: (original.width * factor).rounded(), height: (original.height * factor).rounded())
            } else {
                target = CGSize(width: width, height: height)
            }
        }
        let limit = Double(Bitmap.maximumDimension)
        let size = CGSize(width: min(max(target.width, 1), limit), height: min(max(target.height, 1), limit))
        return Bitmap.render(size: size) { context in
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// `image` with everything but its subjects made transparent, found as
    /// Select Subject finds them.
    static func removingBackground(from image: CGImage) throws -> CGImage {
        let composition = Composition(image: image, name: "")
        let mask = try ObjectSelector.select(in: composition, at: nil)
        return keeping(Selection(shape: .mask(mask)), of: image)
    }

    /// Only the part of `image` that `selection` covers.
    static func keeping(_ selection: Selection, of image: CGImage) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        return Bitmap.render(size: size) { context in
            selection.clip(context, canvasSize: size)
            Bitmap.draw(image, in: CGRect(origin: .zero, size: size), context: context)
        }
    }

    /// The picture written as `format`; `quality` is for JPEG and HEIC.
    static func data(for image: CGImage, as format: CompositionExport.Format, quality: Double = 0.92) throws -> Data {
        switch format {
        case .png, .jpeg, .heic:
            return try ImageCodec.encode(image, as: format.contentType, quality: quality)
        case .psd, .easel:
            return try PSDWriter.data(for: Composition(image: image, name: String(localized: "Layer.DefaultName.Background")))
        case .svg:
            return SVGWriter.data(for: Composition(image: image, name: String(localized: "Layer.DefaultName.Background")))
        case .pdf:
            return PDFWriter.data(for: Composition(image: image, name: String(localized: "Layer.DefaultName.Background")))
        }
    }

    /// `filename` with its extension changed to suit `format`.
    static func filename(_ filename: String, as format: CompositionExport.Format) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return (stem.isEmpty ? String(localized: "Intent.DefaultName") : stem) + "." + format.pathExtension
    }
}
