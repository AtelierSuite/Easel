import Foundation

enum GIF {
    static func decode(_ bytes: [UInt8]) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let frame = firstFrame(bytes) else { return nil }
        let canvasWidth = frame.screenWidth > 0 ? frame.screenWidth : frame.left + frame.width
        let canvasHeight = frame.screenHeight > 0 ? frame.screenHeight : frame.top + frame.height
        guard canvasWidth > 0, canvasHeight > 0, canvasWidth * canvasHeight <= 1 << 28 else { return nil }
        var rgba = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
        let pixelCount = frame.width * frame.height
        guard pixelCount > 0 else { return (canvasWidth, canvasHeight, rgba) }

        var data: [UInt8] = []
        data.reserveCapacity(bytes.count - frame.dataStart)
        var p = frame.dataStart
        while p < bytes.count {
            let n = Int(bytes[p])
            p += 1
            if n == 0 { break }
            let end = min(p + n, bytes.count)
            data += bytes[p..<end]
            p = end
        }

        var indices = [UInt8](repeating: 0, count: pixelCount)
        let decoded = indices.withUnsafeMutableBufferPointer { out in
            lzw(data, minCodeSize: frame.minCodeSize, into: out.baseAddress!, count: pixelCount)
        }

        var rowMap = [Int](repeating: 0, count: frame.height)
        if frame.interlaced {
            var i = 0
            for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
                for y in stride(from: start, to: frame.height, by: step) {
                    rowMap[i] = y
                    i += 1
                }
            }
        } else {
            for y in 0..<frame.height { rowMap[y] = y }
        }

        let palette = frame.palette
        let paletteCount = palette.count / 3
        let transparent = frame.transparentIndex
        rgba.withUnsafeMutableBufferPointer { out in
            indices.withUnsafeBufferPointer { idx in
                palette.withUnsafeBufferPointer { pal in
                    let rowsDecoded = (decoded + frame.width - 1) / frame.width
                    for i in 0..<min(rowsDecoded, frame.height) {
                        let cy = frame.top + rowMap[i]
                        if cy >= canvasHeight { continue }
                        let rowEnd = min(frame.width, decoded - i * frame.width)
                        for x in 0..<rowEnd {
                            let cx = frame.left + x
                            if cx >= canvasWidth { break }
                            let index = Int(idx[i * frame.width + x])
                            if index == transparent { continue }
                            let o = (cy * canvasWidth + cx) * 4
                            if index < paletteCount {
                                out[o] = pal[index * 3]
                                out[o + 1] = pal[index * 3 + 1]
                                out[o + 2] = pal[index * 3 + 2]
                            } else {
                                out[o] = 0
                                out[o + 1] = 0
                                out[o + 2] = 0
                            }
                            out[o + 3] = 255
                        }
                    }
                }
            }
        }
        return (canvasWidth, canvasHeight, rgba)
    }

    static func info(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 13, isGIF(bytes) else { return nil }
        let w = Int(bytes[6]) | Int(bytes[7]) << 8
        let h = Int(bytes[8]) | Int(bytes[9]) << 8
        if w > 0 && h > 0 { return (w, h) }
        guard let frame = firstFrame(bytes) else { return nil }
        let fw = frame.left + frame.width
        let fh = frame.top + frame.height
        return fw > 0 && fh > 0 ? (fw, fh) : nil
    }

    private struct Frame {
        var screenWidth: Int
        var screenHeight: Int
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var interlaced: Bool
        var palette: [UInt8]
        var transparentIndex: Int
        var minCodeSize: Int
        var dataStart: Int
    }

    private static func isGIF(_ b: [UInt8]) -> Bool {
        b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61
    }

    private static func firstFrame(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count >= 13, isGIF(bytes) else { return nil }
        let screenWidth = Int(bytes[6]) | Int(bytes[7]) << 8
        let screenHeight = Int(bytes[8]) | Int(bytes[9]) << 8
        let flags = Int(bytes[10])
        var p = 13
        var globalPalette: [UInt8] = []
        if flags & 0x80 != 0 {
            let size = 3 << ((flags & 7) + 1)
            guard p + size <= bytes.count else { return nil }
            globalPalette = Array(bytes[p..<(p + size)])
            p += size
        }
        var transparent = -1
        while p < bytes.count {
            let introducer = bytes[p]
            p += 1
            switch introducer {
            case 0x21:
                guard p < bytes.count else { return nil }
                let label = bytes[p]
                p += 1
                if label == 0xF9 && p + 5 < bytes.count && bytes[p] >= 4 {
                    transparent = bytes[p + 1] & 1 != 0 ? Int(bytes[p + 4]) : -1
                }
                while p < bytes.count {
                    let n = Int(bytes[p])
                    p += 1
                    if n == 0 { break }
                    p += n
                }
            case 0x2C:
                guard p + 9 <= bytes.count else { return nil }
                let left = Int(bytes[p]) | Int(bytes[p + 1]) << 8
                let top = Int(bytes[p + 2]) | Int(bytes[p + 3]) << 8
                let width = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8
                let height = Int(bytes[p + 6]) | Int(bytes[p + 7]) << 8
                let packed = Int(bytes[p + 8])
                p += 9
                var palette = globalPalette
                if packed & 0x80 != 0 {
                    let size = 3 << ((packed & 7) + 1)
                    guard p + size <= bytes.count else { return nil }
                    palette = Array(bytes[p..<(p + size)])
                    p += size
                }
                if palette.isEmpty {
                    palette = (0..<256).flatMap { [UInt8($0), UInt8($0), UInt8($0)] }
                }
                guard p < bytes.count else { return nil }
                let minCodeSize = Int(bytes[p])
                p += 1
                return Frame(screenWidth: screenWidth, screenHeight: screenHeight, left: left, top: top,
                             width: width, height: height, interlaced: packed & 0x40 != 0, palette: palette,
                             transparentIndex: transparent, minCodeSize: minCodeSize, dataStart: p)
            default:
                return nil
            }
        }
        return nil
    }

    private static func lzw(_ data: [UInt8], minCodeSize: Int, into out: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard minCodeSize >= 1, minCodeSize <= 11 else { return 0 }
        let clear = 1 << minCodeSize
        let end = clear + 1
        var prefix = [Int16](repeating: 0, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var stack = [UInt8](repeating: 0, count: 4097)
        for i in 0..<clear { suffix[i] = UInt8(truncatingIfNeeded: i) }
        var size = minCodeSize + 1
        var mask = (1 << size) - 1
        var next = clear + 2
        var previous = -1
        var first = 0
        var bitBuffer = 0
        var bitCount = 0
        var input = 0
        var written = 0
        prefix.withUnsafeMutableBufferPointer { prefix in
            suffix.withUnsafeMutableBufferPointer { suffix in
                stack.withUnsafeMutableBufferPointer { stack in
                    data.withUnsafeBufferPointer { data in
                        decoding: while written < count {
                            while bitCount < size {
                                if input >= data.count { break decoding }
                                bitBuffer |= Int(data[input]) << bitCount
                                input += 1
                                bitCount += 8
                            }
                            let code = bitBuffer & mask
                            bitBuffer >>= size
                            bitCount -= size
                            if code == clear {
                                size = minCodeSize + 1
                                mask = (1 << size) - 1
                                next = clear + 2
                                previous = -1
                                continue
                            }
                            if code == end { break }
                            if previous < 0 {
                                if code >= clear { break }
                                out[written] = UInt8(truncatingIfNeeded: code)
                                written += 1
                                previous = code
                                first = code
                                continue
                            }
                            var c = code
                            var sp = 0
                            if code >= next {
                                if code > next { break }
                                stack[sp] = UInt8(truncatingIfNeeded: first)
                                sp += 1
                                c = previous
                            }
                            while c >= clear && sp < 4096 {
                                stack[sp] = suffix[c]
                                sp += 1
                                c = Int(prefix[c])
                            }
                            first = c
                            stack[sp] = UInt8(truncatingIfNeeded: c)
                            sp += 1
                            while sp > 0 && written < count {
                                sp -= 1
                                out[written] = stack[sp]
                                written += 1
                            }
                            if next < 4096 {
                                prefix[next] = Int16(previous)
                                suffix[next] = UInt8(truncatingIfNeeded: first)
                                next += 1
                                if next == mask + 1 && size < 12 {
                                    size += 1
                                    mask = (1 << size) - 1
                                }
                            }
                            previous = code
                        }
                    }
                }
            }
        }
        return written
    }
}
