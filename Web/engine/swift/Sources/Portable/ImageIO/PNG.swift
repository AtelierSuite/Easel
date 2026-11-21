import Foundation
import zlib

enum PNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func info(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 24, Array(bytes[0..<8]) == signature else { return nil }
        return (Int(be32(bytes, 16)), Int(be32(bytes, 20)))
    }

    /// RGBA, straight alpha, rows top first.
    static func decode(_ bytes: [UInt8]) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard bytes.count >= 33, Array(bytes[0..<8]) == signature else { return nil }
        var offset = 8
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var compressed: [UInt8] = []
        while offset + 12 <= bytes.count {
            let length = Int(be32(bytes, offset))
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            let start = offset + 8
            guard length >= 0, start + length <= bytes.count else { break }
            let chunk = bytes[start ..< start + length]
            switch type {
            case "IHDR":
                guard length >= 13 else { return nil }
                width = Int(be32(bytes, start))
                height = Int(be32(bytes, start + 4))
                depth = Int(bytes[start + 8])
                colorType = Int(bytes[start + 9])
                interlace = Int(bytes[start + 12])
            case "PLTE": palette = Array(chunk)
            case "tRNS": transparency = Array(chunk)
            case "IDAT": compressed.append(contentsOf: chunk)
            default: break
            }
            offset = start + length + 4
            if type == "IEND" { break }
        }
        guard width > 0, height > 0, width <= 32768, height <= 32768, [1, 2, 4, 8, 16].contains(depth) else { return nil }
        let channels: Int
        switch colorType {
        case 0, 3: channels = 1
        case 2: channels = 3
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        let bitsPerPixel = channels * depth
        let bytesPerPixel = max(bitsPerPixel / 8, 1)
        func rowBytes(_ w: Int) -> Int { (w * bitsPerPixel + 7) / 8 }
        var expected = 0
        let passes: [(x0: Int, y0: Int, dx: Int, dy: Int)] = interlace == 1
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        for p in passes {
            let w = (width - p.x0 + p.dx - 1) / p.dx, h = (height - p.y0 + p.dy - 1) / p.dy
            if w > 0, h > 0 { expected += (rowBytes(w) + 1) * h }
        }
        guard let raw = inflate(compressed, expected: expected), raw.count >= expected else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var cursor = 0
        for p in passes {
            let w = (width - p.x0 + p.dx - 1) / p.dx, h = (height - p.y0 + p.dy - 1) / p.dy
            guard w > 0, h > 0 else { continue }
            let stride = rowBytes(w)
            var previous = [UInt8](repeating: 0, count: stride)
            var line = [UInt8](repeating: 0, count: stride)
            for y in 0..<h {
                let filter = raw[cursor]
                cursor += 1
                for i in 0..<stride { line[i] = raw[cursor + i] }
                cursor += stride
                unfilter(&line, previous: previous, filter: filter, bytesPerPixel: bytesPerPixel)
                let oy = p.y0 + y * p.dy
                for x in 0..<w {
                    let ox = p.x0 + x * p.dx
                    let o = (oy * width + ox) * 4
                    func sample(_ channel: Int) -> Int {
                        if depth == 8 { return Int(line[x * channels + channel]) }
                        if depth == 16 { return Int(line[(x * channels + channel) * 2]) }
                        let bit = (x * channels + channel) * depth
                        let byte = Int(line[bit / 8])
                        let shift = 8 - depth - bit % 8
                        return (byte >> shift) & ((1 << depth) - 1)
                    }
                    func scaled(_ v: Int) -> UInt8 {
                        switch depth {
                        case 1: return v != 0 ? 255 : 0
                        case 2: return UInt8(v * 85)
                        case 4: return UInt8(v * 17)
                        default: return UInt8(v)
                        }
                    }
                    switch colorType {
                    case 0:
                        let v = sample(0)
                        let g = scaled(v)
                        out[o] = g; out[o + 1] = g; out[o + 2] = g
                        var a: UInt8 = 255
                        if transparency.count >= 2 {
                            let key = Int(transparency[0]) << 8 | Int(transparency[1])
                            let raw16 = depth == 16 ? Int(line[x * 2]) << 8 | Int(line[x * 2 + 1]) : v
                            if raw16 == key { a = 0 }
                        }
                        out[o + 3] = a
                    case 2:
                        out[o] = UInt8(sample(0)); out[o + 1] = UInt8(sample(1)); out[o + 2] = UInt8(sample(2))
                        var a: UInt8 = 255
                        if transparency.count >= 6 {
                            let r = Int(transparency[0]) << 8 | Int(transparency[1])
                            let g = Int(transparency[2]) << 8 | Int(transparency[3])
                            let b = Int(transparency[4]) << 8 | Int(transparency[5])
                            let values = depth == 16
                                ? (0..<3).map { Int(line[(x * 3 + $0) * 2]) << 8 | Int(line[(x * 3 + $0) * 2 + 1]) }
                                : [sample(0), sample(1), sample(2)]
                            if values == [r, g, b] { a = 0 }
                        }
                        out[o + 3] = a
                    case 3:
                        let index = sample(0)
                        if index * 3 + 2 < palette.count {
                            out[o] = palette[index * 3]; out[o + 1] = palette[index * 3 + 1]; out[o + 2] = palette[index * 3 + 2]
                        }
                        out[o + 3] = index < transparency.count ? transparency[index] : 255
                    case 4:
                        let g = UInt8(sample(0))
                        out[o] = g; out[o + 1] = g; out[o + 2] = g; out[o + 3] = UInt8(sample(1))
                    default:
                        out[o] = UInt8(sample(0)); out[o + 1] = UInt8(sample(1)); out[o + 2] = UInt8(sample(2)); out[o + 3] = UInt8(sample(3))
                    }
                }
                swap(&previous, &line)
            }
        }
        return (width, height, out)
    }

    private static func unfilter(_ line: inout [UInt8], previous: [UInt8], filter: UInt8, bytesPerPixel bpp: Int) {
        let n = line.count
        line.withUnsafeMutableBufferPointer { l in
            previous.withUnsafeBufferPointer { p in
                switch filter {
                case 1: for i in bpp..<max(n, bpp) where i < n { l[i] = l[i] &+ l[i - bpp] }
                case 2: for i in 0..<n { l[i] = l[i] &+ p[i] }
                case 3:
                    for i in 0..<n {
                        let left = i >= bpp ? Int(l[i - bpp]) : 0
                        l[i] = l[i] &+ UInt8((left + Int(p[i])) / 2)
                    }
                case 4:
                    for i in 0..<n {
                        let a = i >= bpp ? Int(l[i - bpp]) : 0
                        let b = Int(p[i])
                        let c = i >= bpp ? Int(p[i - bpp]) : 0
                        let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                        let predictor = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                        l[i] = l[i] &+ UInt8(predictor)
                    }
                default: break
                }
            }
        }
    }

    /// RGBA with straight alpha in, a PNG out. Opaque pictures are written without alpha.
    static func encode(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var opaque = true
        for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] != 255 {
            opaque = false
            break
        }
        let channels = opaque ? 3 : 4
        let stride = width * channels
        var raw = [UInt8](repeating: 0, count: (stride + 1) * height)
        var line = [UInt8](repeating: 0, count: stride)
        var previous = [UInt8](repeating: 0, count: stride)
        var candidate = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels { line[x * channels + c] = rgba[(y * width + x) * 4 + c] }
            }
            var bestScore = Int.max
            var bestFilter: UInt8 = 0
            for filter in UInt8(0)...4 {
                var score = 0
                for i in 0..<stride {
                    let a = i >= channels ? Int(line[i - channels]) : 0
                    let b = Int(previous[i])
                    let c = i >= channels ? Int(previous[i - channels]) : 0
                    let predictor: Int
                    switch filter {
                    case 1: predictor = a
                    case 2: predictor = b
                    case 3: predictor = (a + b) / 2
                    case 4:
                        let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                        predictor = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                    default: predictor = 0
                    }
                    let value = UInt8(truncatingIfNeeded: Int(line[i]) - predictor)
                    candidate[i] = value
                    score += abs(Int(Int8(bitPattern: value)))
                }
                if score < bestScore {
                    bestScore = score
                    bestFilter = filter
                    swap(&best, &candidate)
                }
            }
            raw[y * (stride + 1)] = bestFilter
            for i in 0..<stride { raw[y * (stride + 1) + 1 + i] = best[i] }
            swap(&previous, &line)
        }
        var out = signature
        var header = [UInt8]()
        header += be32(UInt32(width)) + be32(UInt32(height))
        header += [8, opaque ? 2 : 6, 0, 0, 0]
        chunk("IHDR", header, into: &out)
        chunk("IDAT", deflate(raw), into: &out)
        chunk("IEND", [], into: &out)
        return out
    }

    private static func chunk(_ type: String, _ data: [UInt8], into out: inout [UInt8]) {
        let typeBytes = Array(type.utf8)
        out += be32(UInt32(data.count))
        out += typeBytes
        out += data
        var crc = crc32(0, typeBytes, uInt(typeBytes.count))
        crc = data.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, uInt(data.count)) }
        out += be32(UInt32(crc))
    }

    static func inflate(_ data: [UInt8], expected: Int) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: max(expected, 1))
        var input = data
        var status: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { inBuffer in
            out.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                status = zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR else { return nil }
        return Array(out[0..<Int(stream.total_out)])
    }

    static func deflate(_ data: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        guard deflateInit_(&stream, 6, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        var input = data
        input.withUnsafeMutableBufferPointer { inBuffer in
            out.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                _ = zlib.deflate(&stream, Z_FINISH)
            }
        }
        return Array(out[0..<Int(stream.total_out)])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]
    }
}
