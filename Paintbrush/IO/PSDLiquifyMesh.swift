import CoreGraphics
import Foundation

/// Photoshop's Liquify smart filter keeps its distortion as a mesh (the
/// filter's `LqMe` data): after a four-byte count, "LqfyMesh" and then
/// little-endian numbers: a version, the grid's columns and rows, two
/// flags, the bounds of what was liquified and the bounds the grid covers,
/// each top, left, bottom, right in canvas pixels. Then each row of the
/// grid, as its first column and how many follow, and for each an offset
/// across and down, in cells. A point sits in the middle of its cell, and
/// each pixel is taken from as far off as the grid there says.
package enum PSDLiquifyMesh {
    private static let tag = Array("yfqLhseM".utf8)

    /// The mesh as Easel keeps it, over the contents placed as `placement`
    /// says; nil if it is not a mesh Easel can read.
    package static func mesh(from bytes: [UInt8], placement: PSDSmartFilters.Placement) -> FilterMesh? {
        guard bytes.count >= 64, Array(bytes[4..<12]) == tag else { return nil }
        func uint(_ offset: Int) -> Int {
            Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        func float(_ offset: Int) -> Double {
            Double(Float(bitPattern: UInt32(uint(offset))))
        }
        let columns = uint(16), rows = uint(20)
        let top = Double(Int32(truncatingIfNeeded: uint(48))), left = Double(Int32(truncatingIfNeeded: uint(52)))
        let bottom = Double(Int32(truncatingIfNeeded: uint(56))), right = Double(Int32(truncatingIfNeeded: uint(60)))
        guard uint(12) == 2, columns > 1, rows > 1, columns * rows < 4_000_000, right > left, bottom > top else { return nil }
        // The grid on the canvas, in canvas pixels.
        var grid = [Float](repeating: 0, count: columns * rows * 2)
        var offset = 64
        for row in 0..<rows {
            guard offset + 8 <= bytes.count else { return nil }
            let first = uint(offset), count = uint(offset + 4)
            offset += 8
            guard first + count <= columns, offset + count * 8 <= bytes.count else { return nil }
            for column in first..<(first + count) {
                grid[(row * columns + column) * 2] = Float(float(offset))
                grid[(row * columns + column) * 2 + 1] = Float(float(offset + 4))
                offset += 8
            }
        }
        let cell = SIMD2((right - left) / Double(columns), (bottom - top) / Double(rows))
        let canvas = FilterMesh(columns: columns, rows: rows, offsets: grid)
        // Moved into the contents' own pixels: each point of a grid as fine
        // over them looks up where it lies on the canvas, and the offset
        // there is turned back through the placement.
        let size = SIMD2(Double(placement.size.width), Double(placement.size.height))
        let fromCanvas = placement.toCanvas.inverted()
        return FilterMesh.sampling(columns: columns, rows: rows) { x, y in
            let point = CGPoint(x: x * size.x, y: y * size.y).applying(placement.toCanvas)
            let moved = canvas.offset(x: (point.x - left) / (right - left), y: (point.y - top) / (bottom - top)) * cell
            let back = CGSize(width: moved.x, height: moved.y).applying(fromCanvas)
            return SIMD2(back.width, back.height) / size
        }
    }

    /// The mesh as Photoshop keeps it, a grid over the placed layer's
    /// bounds on the canvas, its offsets `amount` as strong.
    package static func bytes(for mesh: FilterMesh, amount: Double, placement: PSDSmartFilters.Placement) -> [UInt8] {
        let size = SIMD2(Double(placement.size.width), Double(placement.size.height))
        let rect = CGRect(origin: .zero, size: placement.size).applying(placement.toCanvas).integral
        // About four pixels to a cell, as Photoshop's are.
        let columns = min(max(Int(rect.width / 4), 8), 256), rows = min(max(Int(rect.height / 4), 8), 256)
        let cell = SIMD2(rect.width / Double(columns), rect.height / Double(rows))
        let fromCanvas = placement.toCanvas.inverted()
        var out: [UInt8] = [0, 0, 0, 4] + tag
        func uint(_ value: Int) {
            let bits = UInt32(truncatingIfNeeded: value)
            out += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        }
        let bounds = [Int(rect.minY), Int(rect.minX), Int(rect.maxY), Int(rect.maxX)]
        for value in [2, columns, rows, 0, 1] + bounds + bounds { uint(value) }
        for row in 0..<rows {
            uint(0)
            uint(columns)
            for column in 0..<columns {
                let point = CGPoint(x: rect.minX + (Double(column) + 0.5) * cell.x, y: rect.minY + (Double(row) + 0.5) * cell.y)
                let inside = point.applying(fromCanvas)
                let moved = mesh.offset(x: inside.x / size.x, y: inside.y / size.y) * size * amount
                let onCanvas = CGSize(width: moved.x, height: moved.y).applying(placement.toCanvas)
                uint(Int(Float(onCanvas.width / cell.x).bitPattern))
                uint(Int(Float(onCanvas.height / cell.y).bitPattern))
            }
        }
        return out
    }
}
