import CoreGraphics
import Foundation

/// Photoshop's vector masks (`vmsk`, `vsms`): paths that hide what lies
/// outside them, drawn out as pixels so they can join the layer's mask.
enum PSDVectorMask {
    private struct Knot {
        var preceding: CGPoint
        var anchor: CGPoint
        var leaving: CGPoint
    }

    private struct Subpath {
        var knots: [Knot] = []
        var isClosed: Bool
        /// How it joins the shape so far: 0 exclude, 1 combine, 2 subtract,
        /// 3 intersect, -1 part of the subpath before it.
        var operation: Int
    }

    /// How much each canvas pixel shows, 0...255, top row first; nil when
    /// the mask is turned off or cannot be read.
    static func coverage(_ block: [UInt8], width: Int, height: Int) -> [UInt8]? {
        var reader = BigEndianReader(bytes: block)
        guard width > 0, height > 0, (try? reader.uint32()) == 3, let flags = try? reader.uint32(), flags & 0x04 == 0
        else { return nil }
        var subpaths: [Subpath] = []
        var startsFilled = false
        func point() throws -> CGPoint {
            // Fixed point, 8.24, as fractions of the canvas, y first.
            let y = Double(try reader.int32()) / 16_777_216
            let x = Double(try reader.int32()) / 16_777_216
            return CGPoint(x: x * Double(width), y: y * Double(height))
        }
        while reader.remaining >= 26 {
            guard let selector = try? reader.uint16() else { break }
            let start = reader.offset
            switch selector {
            case 0, 3:
                _ = try? reader.uint16()
                let operation = Int((try? reader.int16()) ?? 1)
                subpaths.append(Subpath(isClosed: selector == 0, operation: operation))
            case 1, 2, 4, 5:
                guard !subpaths.isEmpty, let preceding = try? point(), let anchor = try? point(), let leaving = try? point() else { break }
                subpaths[subpaths.count - 1].knots.append(Knot(preceding: preceding, anchor: anchor, leaving: leaving))
            case 8:
                startsFilled = ((try? reader.uint16()) ?? 0) == 1
            default:
                break
            }
            guard reader.seek(to: start + 24) else { break }
        }

        // Subpaths that belong together are drawn as one.
        var groups: [[Subpath]] = []
        for subpath in subpaths {
            if subpath.operation == -1, !groups.isEmpty { groups[groups.count - 1].append(subpath) } else { groups.append([subpath]) }
        }
        let count = width * height
        var mask = [Float](repeating: startsFilled && groups.isEmpty ? 1 : 0, count: count)
        for (index, group) in groups.enumerated() {
            let path = CGMutablePath()
            for subpath in group where subpath.knots.count > 1 {
                let knots = subpath.knots
                path.move(to: knots[0].anchor)
                for i in 1..<knots.count {
                    path.addCurve(to: knots[i].anchor, control1: knots[i - 1].leaving, control2: knots[i].preceding)
                }
                if subpath.isClosed {
                    path.addCurve(to: knots[0].anchor, control1: knots[knots.count - 1].leaving, control2: knots[0].preceding)
                    path.closeSubpath()
                }
            }
            let plane = Bitmap.mask(for: path, width: width, height: height)
            let operation = group.first?.operation ?? 1
            // A first shape that cuts away cuts from everything.
            if index == 0, operation == 2 || operation == 3 { mask = mask.map { 1 - $0 } }
            for pixel in 0..<count {
                let m = mask[pixel], p = Float(plane[pixel]) / 255
                switch operation {
                case 0: mask[pixel] = m + p - 2 * m * p
                case 2: mask[pixel] = max(0, m - p)
                case 3: mask[pixel] = m * p
                default: mask[pixel] = m + p - m * p
                }
            }
        }
        if flags & 0x01 != 0 { mask = mask.map { 1 - $0 } }
        return mask.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }
}
