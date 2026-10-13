import CoreGraphics
import CoreImage
import Foundation

/// Filters worked out pixel by pixel on the processor, for those Core Image
/// has nothing like or cannot do exactly: Photoshop's adjustments and
/// filters, which work on eight-bit sRGB values with hard steps a lookup
/// cube would soften.
enum PixelFilters {
    /// A picture as eight-bit sRGB, colours not premultiplied, rows from
    /// the top.
    struct Pixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// A transparent picture this size.
        init(width: Int, height: Int) {
            self.init(width: width, height: height, bytes: [UInt8](repeating: 0, count: width * height * 4))
        }

        subscript(x: Int, y: Int, channel: Int) -> UInt8 {
            get { bytes[(y * width + x) * 4 + channel] }
            set { bytes[(y * width + x) * 4 + channel] = newValue }
        }

        /// The pixel nearest a point outside the picture.
        func clamped(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 {
            self[min(max(x, 0), width - 1), min(max(y, 0), height - 1), channel]
        }
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `input` as pixels, `body` run over them, and the result back.
    static func process(_ input: CIImage, _ body: (inout Pixels) -> Void) -> CIImage {
        let extent = input.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width * height < 80_000_000 else { return input }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        ImageProcessing.context.render(
            input, toBitmap: &bytes, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: colorSpace
        )
        // Core Image gives premultiplied colour; the filters work on colour
        // as it is.
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        var pixels = Pixels(width: width, height: height, bytes: bytes)
        body(&pixels)
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let alpha = Int(pixels.bytes[index + 3])
            guard alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels.bytes[index + channel] = UInt8((Int(pixels.bytes[index + channel]) * alpha + 127) / 255)
            }
        }
        let output = CIImage(
            bitmapData: Data(pixels.bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
            format: .RGBA8, colorSpace: colorSpace
        )
        return output.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Every pixel's colour sent through `transform`, which takes and gives
    /// red, green and blue, 0...255.
    static func map(_ input: CIImage, _ transform: (inout SIMD3<Double>) -> Void) -> CIImage {
        process(input) { pixels in
            for index in stride(from: 0, to: pixels.bytes.count, by: 4) where pixels.bytes[index + 3] > 0 {
                var color = SIMD3(Double(pixels.bytes[index]), Double(pixels.bytes[index + 1]), Double(pixels.bytes[index + 2]))
                transform(&color)
                pixels.bytes[index] = byte(color.x)
                pixels.bytes[index + 1] = byte(color.y)
                pixels.bytes[index + 2] = byte(color.z)
            }
        }
    }

    /// Each channel looked up in a table of 256.
    static func table(_ input: CIImage, _ entry: (Int) -> Double) -> CIImage {
        let table = (0..<256).map { byte(entry($0)) }
        return process(input) { pixels in
            for index in stride(from: 0, to: pixels.bytes.count, by: 4) where pixels.bytes[index + 3] > 0 {
                for channel in 0..<3 { pixels.bytes[index + channel] = table[Int(pixels.bytes[index + channel])] }
            }
        }
    }

    static func byte(_ value: Double) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }

    // MARK: - Colour

    /// `transform` on each channel.
    static func each(_ color: SIMD3<Double>, _ transform: (Double) -> Double) -> SIMD3<Double> {
        SIMD3(transform(color.x), transform(color.y), transform(color.z))
    }

    static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Photoshop's luminosity for its adjustments, 0...255.
    static func luminosity(_ color: SIMD3<Double>) -> Double {
        (299 * color.x + 587 * color.y + 114 * color.z) / 1000
    }
}

/// Colours between the spaces Photoshop's records use and sRGB.
enum ColorConversions {
    /// CIE Lab under D50, as Photoshop keeps it, in sRGB.
    static func srgb(lab: [Double]) -> RGBAColor {
        let fy = (lab[0] + 16) / 116, fx = fy + lab[1] / 500, fz = fy - lab[2] / 200
        func inverse(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * pow(6.0 / 29, 2) * (t - 4.0 / 29) }
        let x50 = 0.9642 * inverse(fx), y50 = inverse(fy), z50 = 0.8249 * inverse(fz)
        // Bradford from D50 to D65, then to linear sRGB.
        let x = 0.9555766 * x50 - 0.0230393 * y50 + 0.0631636 * z50
        let y = -0.0282895 * x50 + 1.0099416 * y50 + 0.0210077 * z50
        let z = 0.0122982 * x50 - 0.0204830 * y50 + 1.3299098 * z50
        let linear = [
            3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
            -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
            0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
        ].map { min(max(PixelFilters.linearToSRGB(max($0, 0)), 0), 1) }
        return RGBAColor(red: linear[0], green: linear[1], blue: linear[2])
    }
}
