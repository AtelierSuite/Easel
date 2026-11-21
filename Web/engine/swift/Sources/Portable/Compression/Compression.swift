import Foundation
import zlib

// Apple's Compression buffer functions over zlib's raw DEFLATE, and LZ4 blocks.

public struct compression_algorithm: Equatable, Sendable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public let COMPRESSION_ZLIB = compression_algorithm(0x205)
public let COMPRESSION_LZ4 = compression_algorithm(0x100)
public let COMPRESSION_LZ4_RAW = compression_algorithm(0x101)
public let COMPRESSION_LZFSE = compression_algorithm(0x801)
public let COMPRESSION_LZMA = compression_algorithm(0x306)

public func compression_encode_buffer(
    _ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
    _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm
) -> Int {
    switch algorithm {
    case COMPRESSION_ZLIB:
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
        defer { deflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: src)
        stream.avail_in = uInt(srcSize)
        stream.next_out = dst
        stream.avail_out = uInt(dstSize)
        guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
        return Int(stream.total_out)
    case COMPRESSION_LZ4_RAW:
        return LZ4.encode(src, srcSize, dst, dstSize)
    case COMPRESSION_LZ4:
        // Apple's LZ4 frames: a "bv41" block header, the block, then "bv4$".
        guard dstSize > 16 else { return 0 }
        let body = LZ4.encode(src, srcSize, dst + 12, dstSize - 16)
        guard body > 0 else { return 0 }
        let header: [UInt8] = [0x62, 0x76, 0x34, 0x31] + le32(srcSize) + le32(body)
        for i in 0..<12 { dst[i] = header[i] }
        let end: [UInt8] = [0x62, 0x76, 0x34, 0x24]
        for i in 0..<4 { dst[12 + body + i] = end[i] }
        return body + 16
    default:
        return 0
    }
}

public func compression_decode_buffer(
    _ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
    _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm
) -> Int {
    switch algorithm {
    case COMPRESSION_ZLIB:
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: src)
        stream.avail_in = uInt(srcSize)
        stream.next_out = dst
        stream.avail_out = uInt(dstSize)
        let status = inflate(&stream, Z_FINISH)
        guard status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR else { return 0 }
        return Int(stream.total_out)
    case COMPRESSION_LZ4_RAW:
        return LZ4.decode(src, srcSize, dst, dstSize)
    case COMPRESSION_LZ4:
        var read = 0, written = 0
        while read + 4 <= srcSize {
            let magic = (0..<4).map { src[read + $0] }
            if magic == [0x62, 0x76, 0x34, 0x24] { break }
            guard read + 12 <= srcSize else { return 0 }
            let raw = Int(le32(src + read + 4)), size = Int(le32(src + read + 8))
            if magic == [0x62, 0x76, 0x34, 0x31] {
                guard read + 12 + size <= srcSize else { return 0 }
                let n = LZ4.decode(src + read + 12, size, dst + written, min(raw, dstSize - written))
                written += n
                read += 12 + size
            } else if magic == [0x62, 0x76, 0x34, 0x2D] {
                let count = Int(le32(src + read + 4))
                let n = min(count, dstSize - written, srcSize - read - 8)
                (dst + written).update(from: src + read + 8, count: n)
                written += n
                read += 8 + count
            } else {
                return LZ4.decode(src, srcSize, dst, dstSize)
            }
        }
        return written
    default:
        return 0
    }
}

public func compression_encode_scratch_buffer_size(_ algorithm: compression_algorithm) -> Int { 0 }
public func compression_decode_scratch_buffer_size(_ algorithm: compression_algorithm) -> Int { 0 }

private func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
private func le32(_ p: UnsafePointer<UInt8>) -> UInt32 { UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24 }

enum LZ4 {
    static func decode(_ src: UnsafePointer<UInt8>, _ srcSize: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int) -> Int {
        var s = 0, d = 0
        while s < srcSize {
            let token = Int(src[s]); s += 1
            var literal = token >> 4
            if literal == 15 {
                while s < srcSize { let b = Int(src[s]); s += 1; literal += b; if b != 255 { break } }
            }
            guard s + literal <= srcSize, d + literal <= dstSize else { return d }
            (dst + d).update(from: src + s, count: literal)
            s += literal; d += literal
            if s >= srcSize { break }
            guard s + 2 <= srcSize else { return d }
            let offset = Int(src[s]) | Int(src[s + 1]) << 8; s += 2
            var match = (token & 15) + 4
            if token & 15 == 15 {
                while s < srcSize { let b = Int(src[s]); s += 1; match += b; if b != 255 { break } }
            }
            guard offset > 0, offset <= d else { return d }
            for _ in 0..<match {
                guard d < dstSize else { return d }
                dst[d] = dst[d - offset]; d += 1
            }
        }
        return d
    }

    static func encode(_ src: UnsafePointer<UInt8>, _ srcSize: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int) -> Int {
        var table = [Int](repeating: -1, count: 1 << 16)
        var s = 0, anchor = 0, d = 0
        func put(_ byte: Int) -> Bool {
            guard d < dstSize else { return false }
            dst[d] = UInt8(truncatingIfNeeded: byte); d += 1
            return true
        }
        func putLength(_ value: Int) -> Bool {
            var v = value
            while v >= 255 { guard put(255) else { return false }; v -= 255 }
            return put(v)
        }
        func emit(literalEnd: Int, offset: Int, match: Int) -> Bool {
            let literal = literalEnd - anchor
            let token = (min(literal, 15) << 4) | (match > 0 ? min(match - 4, 15) : 0)
            guard put(token) else { return false }
            if literal >= 15 { guard putLength(literal - 15) else { return false } }
            guard d + literal <= dstSize else { return false }
            (dst + d).update(from: src + anchor, count: literal); d += literal
            if match > 0 {
                guard put(offset & 255), put(offset >> 8) else { return false }
                if match - 4 >= 15 { guard putLength(match - 4 - 15) else { return false } }
            }
            return true
        }
        while s + 12 < srcSize {
            let sequence = UInt32(src[s]) | UInt32(src[s + 1]) << 8 | UInt32(src[s + 2]) << 16 | UInt32(src[s + 3]) << 24
            let hash = Int((sequence &* 2654435761) >> 16)
            let candidate = table[hash]
            table[hash] = s
            if candidate >= 0, s - candidate < 65535, src[candidate] == src[s], src[candidate + 1] == src[s + 1],
               src[candidate + 2] == src[s + 2], src[candidate + 3] == src[s + 3] {
                var length = 4
                while s + length < srcSize - 5, src[candidate + length] == src[s + length] { length += 1 }
                guard emit(literalEnd: s, offset: s - candidate, match: length) else { return 0 }
                s += length
                anchor = s
            } else {
                s += 1
            }
        }
        guard emit(literalEnd: srcSize, offset: 0, match: 0) else { return 0 }
        return d
    }
}
