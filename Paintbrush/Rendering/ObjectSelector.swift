import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Finds the things in a picture — people, animals, objects — the way
/// lifting a subject from a photo does, and turns one or all of them into a
/// selection.
package enum ObjectSelector {
    package enum Failure: LocalizedError {
        case nothingFound
        case notHere
        /// The device cannot run the model, as in Simulator.
        case unavailable

        package var errorDescription: String? {
            switch self {
            case .nothingFound: return String(localized: "Error.NoObjectFound")
            case .notHere: return String(localized: "Error.NoObjectHere")
            case .unavailable: return String(localized: "Error.ObjectSelectionUnavailable")
            }
        }
    }

    /// The picture is looked at no larger than this; the mask is scaled back
    /// up to the canvas.
    package static let analysisSize = 2048

    /// The object at `point`, in canvas pixels, or every object when `point`
    /// is nil.
    package static func select(in composition: Composition, at point: CGPoint?) throws -> SelectionMask {
        let image = CompositionRenderer.thumbnail(composition, maxPixelSize: analysisSize, background: .white)
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw Failure.unavailable
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.nothingFound
        }

        var instances = observation.allInstances
        if let point {
            let label = Self.label(
                in: observation.instanceMask,
                at: CGPoint(x: point.x / composition.size.width, y: point.y / composition.size.height)
            )
            guard label != 0 else { throw Failure.notHere }
            instances = IndexSet(integer: label)
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        let analysed = bytes(of: buffer)
        guard let scaled = scale(analysed.bytes, width: analysed.width, height: analysed.height, to: composition.size),
              let mask = SelectionMask(
                  bytes: scaled, width: Int(composition.size.width.rounded()), height: Int(composition.size.height.rounded())
              )
        else { throw Failure.nothingFound }
        return mask
    }

    /// Every object in one layer, seen on its own: fully opaque, unmasked
    /// and out of any group, so nothing above or below it is mistaken for
    /// part of it.
    package static func subjects(of layer: Layer, in composition: Composition) throws -> SelectionMask {
        var shown = layer
        shown.isVisible = true
        shown.opacity = 1
        shown.blendMode = .normal
        shown.mask = nil
        shown.groupID = nil
        var solo = composition
        solo.layers = [shown]
        solo.groups = []
        return try select(in: solo, at: nil)
    }

    /// Which object covers a point given as a fraction of the picture,
    /// top left first; 0 for the background.
    private static func label(in buffer: CVPixelBuffer, at unit: CGPoint) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let x = min(max(Int(unit.x * Double(width)), 0), width - 1)
        let y = min(max(Int(unit.y * Double(height)), 0), height - 1)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
        return Int(row.assumingMemoryBound(to: UInt8.self)[x])
    }

    /// A float mask from Vision as bytes, top row first.
    private static func bytes(of buffer: CVPixelBuffer) -> (bytes: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (bytes, width, height) }
        let isFloat = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let value: Float = isFloat
                    ? row.assumingMemoryBound(to: Float.self)[x]
                    : Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                bytes[y * width + x] = UInt8(min(max(value, 0), 1) * 255)
            }
        }
        return (bytes, width, height)
    }

    /// Bytes stretched smoothly to the canvas's size.
    package static func scale(_ bytes: [UInt8], width: Int, height: Int, to size: CGSize) -> [UInt8]? {
        let newWidth = Int(size.width.rounded())
        let newHeight = Int(size.height.rounded())
        if newWidth == width, newHeight == height { return bytes }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        var result = [UInt8](repeating: 0, count: newWidth * newHeight)
        let drawn = result.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: newWidth, height: newHeight, bitsPerComponent: 8,
                bytesPerRow: newWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return true
        }
        return drawn ? result : nil
    }
}
