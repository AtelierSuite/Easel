import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

/// How a newly drawn selection meets the one already there.
enum SelectionMode: String, CaseIterable, Identifiable, Sendable {
    case replace, add, subtract, intersect

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .replace: return "square.dashed"
        case .add: return "plus.square.dashed"
        case .subtract: return "minus.square"
        case .intersect: return "square.on.square.intersection.dashed"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .replace: return "Select.Mode.Replace"
        case .add: return "Select.Mode.Add"
        case .subtract: return "Select.Mode.Subtract"
        case .intersect: return "Select.Mode.Intersect"
        }
    }
}

/// Changes made to a whole selection from the Modify menu.
enum SelectionModification: String, CaseIterable, Identifiable, Sendable {
    /// Softens the edge.
    case feather
    /// Grows the selection outwards.
    case expand
    /// Shrinks it inwards.
    case contract
    /// Rounds off its corners and fills small gaps.
    case smooth
    /// Keeps only a band along its edge.
    case border

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .feather: return "Select.Feather"
        case .expand: return "Select.Expand"
        case .contract: return "Select.Contract"
        case .smooth: return "Select.Smooth"
        case .border: return "Select.Border"
        }
    }

    var symbolName: String {
        switch self {
        case .feather: return "aqi.medium"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .contract: return "arrow.down.right.and.arrow.up.left"
        case .smooth: return "circle.dashed"
        case .border: return "square.dashed.inset.filled"
        }
    }
}

extension Selection {
    /// The selection as pixels on a canvas of `size`, however it was made.
    func mask(canvasSize size: CGSize) -> SelectionMask? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        return SelectionMask(bytes: coverage(width: width, height: height), width: width, height: height)
    }

    /// This selection combined with `other`, drawn after it. Nil when
    /// nothing is left selected.
    func combined(with other: Selection, mode: SelectionMode, canvasSize size: CGSize) -> Selection? {
        guard mode != .replace else { return other }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let mine = coverage(width: width, height: height)
        let theirs = other.coverage(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in bytes.indices {
            let a = mine[index], b = theirs[index]
            switch mode {
            case .replace: bytes[index] = b
            case .add: bytes[index] = max(a, b)
            case .subtract: bytes[index] = min(a, 255 - b)
            case .intersect: bytes[index] = min(a, b)
            }
        }
        return SelectionMask(bytes: bytes, width: width, height: height).map { Selection(shape: .mask($0)) }
    }

    /// The selection changed as a whole, by `radius` canvas pixels. Nil when
    /// nothing is left selected.
    func modified(_ modification: SelectionModification, radius: Double, canvasSize size: CGSize) -> Selection? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let input = SelectionImages.image(coverage(width: width, height: height), width: width, height: height)
        let radius = max(radius, 0)
        let output: CIImage
        switch modification {
        case .feather:
            output = SelectionImages.blur(input, radius / 2)
        case .expand:
            output = SelectionImages.dilate(input, radius)
        case .contract:
            output = SelectionImages.erode(input, radius)
        case .smooth:
            output = SelectionImages.threshold(SelectionImages.blur(input, radius))
        case .border:
            let outer = SelectionImages.dilate(input, radius / 2)
            let inner = SelectionImages.erode(input, radius / 2)
            output = outer.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: inner])
        }
        let bytes = SelectionImages.bytes(of: output, width: width, height: height)
        return SelectionMask(bytes: bytes, width: width, height: height).map { Selection(shape: .mask($0)) }
    }

    /// The selection's edge pulled in to the picture's own edges, so it
    /// follows hair and fur: each soft edge becomes as selected as the
    /// colours there are like those inside.
    func refined(along picture: CGImage, radius: Double) -> Selection? {
        let width = picture.width, height = picture.height
        let input = SelectionImages.image(coverage(width: width, height: height), width: width, height: height)
        // A band either side of the edge is worked out again; the rest
        // stays as it was.
        let refined = SelectionImages.blur(input, radius / 4).applyingFilter("CIGuidedFilter", parameters: [
            "inputGuideImage": CIImage(cgImage: picture),
            "inputRadius": max(1, radius),
            "inputEpsilon": 0.0005,
        ])
        let bytes = SelectionImages.bytes(of: refined, width: width, height: height)
        return SelectionMask(bytes: bytes, width: width, height: height).map { Selection(shape: .mask($0)) }
    }
}

/// Selections as grey Core Image pictures, white where selected.
enum SelectionImages {
    private static let space = CGColorSpaceCreateDeviceGray()

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CIImage {
        CIImage(
            bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height),
            format: .L8, colorSpace: nil
        )
    }

    static func bytes(of image: CIImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(
                image.cropped(to: rect), toBitmap: buffer.baseAddress!, rowBytes: width, bounds: rect,
                format: .L8, colorSpace: nil
            )
        }
        return bytes
    }

    static func blur(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    static func dilate(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.morphologyMaximum()
        filter.inputImage = image
        filter.radius = Float(radius)
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    static func erode(_ image: CIImage, _ radius: Double) -> CIImage {
        guard radius > 0.3 else { return image }
        let filter = CIFilter.morphologyMinimum()
        // Past the canvas nothing is selected, so edges shrink in too.
        filter.inputImage = image.composited(over: CIImage(color: .black).cropped(to: image.extent.insetBy(dx: -radius - 2, dy: -radius - 2)))
        filter.radius = Float(radius)
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    /// Fully in where at least half in, out otherwise, with a pixel of
    /// softening so the edge is not jagged.
    static func threshold(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        let gain: CGFloat = 8
        filter.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        filter.biasVector = CIVector(x: -gain / 2 + 0.5, y: -gain / 2 + 0.5, z: -gain / 2 + 0.5, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = filter.outputImage
        return clamp.outputImage ?? image
    }
}
