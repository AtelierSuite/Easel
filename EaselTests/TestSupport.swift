import CoreGraphics
@testable import Easel
@testable import Paintbrush

/// Small pictures with known pixels, for checking what edits do to them.
enum TestImages {
    static func solid(_ color: RGBAColor, width: Int = 8, height: Int = 8) -> CGImage {
        Bitmap.solid(size: CGSize(width: width, height: height), color: color)
    }

    /// Red on the left half, blue on the right.
    static func halves(width: Int = 8, height: Int = 4) -> CGImage {
        Bitmap.render(size: CGSize(width: width, height: height)) { context in
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
    }

    /// The colour at a pixel as 0...255 channels, alpha unpremultiplied.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        Bitmap.pixels(of: image)!.color(x: x, y: y)
    }

    static func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        let pixel = pixel(image, x: x, y: y)
        return pixel.red > 200 && pixel.green < 60 && pixel.blue < 60 && pixel.alpha > 250
    }

    static func isBlue(_ image: CGImage, x: Int, y: Int) -> Bool {
        let pixel = pixel(image, x: x, y: y)
        return pixel.blue > 200 && pixel.red < 60 && pixel.alpha > 250
    }

    static func isClear(_ image: CGImage, x: Int, y: Int) -> Bool {
        pixel(image, x: x, y: y).alpha == 0
    }
}
