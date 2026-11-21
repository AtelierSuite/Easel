import Foundation

enum JPEG {
    static func decode(_ bytes: [UInt8]) -> (width: Int, height: Int, rgba: [UInt8], orientation: Int)? {
        bytes.withUnsafeBufferPointer { buffer in
            var decoder = JPEGDecoder(data: buffer)
            guard decoder.parse(headerOnly: false), let rgba = decoder.render() else { return nil }
            return (decoder.width, decoder.height, rgba, decoder.orientation)
        }
    }

    static func info(_ bytes: [UInt8]) -> (width: Int, height: Int, orientation: Int)? {
        bytes.withUnsafeBufferPointer { buffer in
            var decoder = JPEGDecoder(data: buffer)
            guard decoder.parse(headerOnly: true) else { return nil }
            return (decoder.width, decoder.height, decoder.orientation)
        }
    }

    static func encode(rgba: [UInt8], width: Int, height: Int, quality: Double) -> [UInt8] {
        JPEGEncoder.encode(rgba: rgba, width: width, height: height, quality: quality)
    }
}

private enum JPEGTables {
    static let dezigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static let lumaQuant: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]

    static let chromaQuant: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]

    static let dcLumaBits: [Int] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    static let dcChromaBits: [Int] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
    static let dcValues: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    static let acLumaBits: [Int] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    static let acLumaValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    static let acChromaBits: [Int] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
    static let acChromaValues: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]
}

// MARK: - Decoding

private struct JPEGHuffman {
    // (length << 8) | symbol for codes of up to 9 bits; 0 when the slow path is needed.
    var fast = [UInt16](repeating: 0, count: 512)
    var maxCode = [UInt32](repeating: 0, count: 18)
    var delta = [Int](repeating: 0, count: 18)
    var values = [UInt8](repeating: 0, count: 256)

    init?(counts: [Int], symbols: [UInt8]) {
        guard counts.count == 16 else { return nil }
        var sizes: [Int] = []
        for length in 1...16 {
            for _ in 0..<counts[length - 1] { sizes.append(length) }
        }
        guard sizes.count <= 256, sizes.count <= symbols.count else { return nil }
        for (i, symbol) in symbols.prefix(sizes.count).enumerated() { values[i] = symbol }
        var codes = [Int](repeating: 0, count: sizes.count)
        var code = 0
        var k = 0
        for length in 1...16 {
            delta[length] = k - code
            while k < sizes.count && sizes[k] == length {
                codes[k] = code
                code += 1
                k += 1
            }
            if code > (1 << length) { return nil }
            maxCode[length] = UInt32(code) << UInt32(16 - length)
            code <<= 1
        }
        maxCode[17] = UInt32.max
        for i in 0..<sizes.count where sizes[i] <= 9 {
            let size = sizes[i]
            let first = codes[i] << (9 - size)
            let entry = UInt16(size << 8) | UInt16(values[i])
            for j in 0..<(1 << (9 - size)) { fast[first + j] = entry }
        }
    }
}

private struct JPEGBitReader {
    let data: UnsafeBufferPointer<UInt8>
    var pos: Int
    var buffer: UInt64 = 0
    var count = 0
    var atMarker = false
    var padding = 0

    init(data: UnsafeBufferPointer<UInt8>, pos: Int) {
        self.data = data
        self.pos = pos
    }

    @inline(__always) mutating func fill() {
        while count <= 56 {
            var byte: UInt64 = 0
            if !atMarker && pos < data.count {
                let b = data[pos]
                if b == 0xFF {
                    let next = pos + 1 < data.count ? data[pos + 1] : 0xD9
                    if next == 0 {
                        byte = 0xFF
                        pos += 2
                    } else {
                        atMarker = true
                        padding += 1
                    }
                } else {
                    byte = UInt64(b)
                    pos += 1
                }
            } else {
                padding += 1
            }
            buffer |= byte << UInt64(56 - count)
            count += 8
        }
    }

    @inline(__always) mutating func bit() -> Int {
        if count < 1 { fill() }
        let v = Int(truncatingIfNeeded: buffer >> 63)
        buffer <<= 1
        count -= 1
        return v
    }

    @inline(__always) mutating func bits(_ n: Int) -> Int {
        if n == 0 { return 0 }
        if count < n { fill() }
        let v = Int(truncatingIfNeeded: buffer >> UInt64(64 - n))
        buffer <<= UInt64(n)
        count -= n
        return v
    }

    @inline(__always) mutating func extend(_ n: Int) -> Int {
        if n == 0 { return 0 }
        let v = bits(n)
        return v < (1 << (n - 1)) ? v - (1 << n) + 1 : v
    }

    @inline(__always) mutating func decode(_ table: JPEGHuffman) -> Int {
        if count < 16 { fill() }
        let entry = table.fast[Int(truncatingIfNeeded: buffer >> 55)]
        if entry != 0 {
            let length = Int(entry >> 8)
            buffer <<= UInt64(length)
            count -= length
            return Int(entry & 0xFF)
        }
        let top = UInt32(truncatingIfNeeded: buffer >> 48)
        var k = 10
        while k <= 16 && top >= table.maxCode[k] { k += 1 }
        if k > 16 { return -1 }
        let index = Int(top >> UInt32(16 - k)) + table.delta[k]
        guard index >= 0 && index < 256 else { return -1 }
        buffer <<= UInt64(k)
        count -= k
        return Int(table.values[index])
    }

    mutating func restart() {
        buffer = 0
        count = 0
        atMarker = false
        padding = 0
        var p = pos
        while p + 1 < data.count {
            if data[p] == 0xFF {
                let m = data[p + 1]
                if m >= 0xD0 && m <= 0xD7 {
                    pos = p + 2
                    return
                }
                if m != 0 && m != 0xFF {
                    pos = p
                    atMarker = true
                    return
                }
            }
            p += 1
        }
        pos = data.count
    }
}

private struct JPEGComponent {
    var id: Int
    var h: Int
    var v: Int
    var tq: Int
    var width = 0
    var height = 0
    var blocksPerLine = 0
    var blocksPerColumn = 0
    var stride = 0
    var offset = 0
}

private enum JPEGScanMode {
    case baseline, dcFirst, dcRefine, acFirst, acRefine
}

private struct JPEGScan {
    var components: [Int]
    var dc: [JPEGHuffman]
    var ac: [JPEGHuffman]
    var ss: Int
    var se: Int
    var al: Int
    var mode: JPEGScanMode
}

private enum JPEGColorTransform {
    case gray, ycc, rgb, cmyk, ycck
}

private struct JPEGDecoder {
    let data: UnsafeBufferPointer<UInt8>
    var pos = 0
    var quant = [[Int32]](repeating: [Int32](repeating: 1, count: 64), count: 4)
    var dcTables = [JPEGHuffman?](repeating: nil, count: 4)
    var acTables = [JPEGHuffman?](repeating: nil, count: 4)
    var components: [JPEGComponent] = []
    var width = 0
    var height = 0
    var hmax = 1
    var vmax = 1
    var mcusX = 0
    var mcusY = 0
    var progressive = false
    var frameFound = false
    var scansDecoded = 0
    var restartInterval = 0
    var adobeTransform = -1
    var orientation = 1
    var coefficients: [Int16] = []

    init(data: UnsafeBufferPointer<UInt8>) {
        self.data = data
    }

    private func u16(_ p: Int) -> Int {
        p + 1 < data.count ? Int(data[p]) << 8 | Int(data[p + 1]) : 0
    }

    private mutating func nextMarker() -> UInt8? {
        while pos + 1 < data.count {
            if data[pos] == 0xFF {
                let m = data[pos + 1]
                if m != 0 && m != 0xFF && !(m >= 0xD0 && m <= 0xD7) {
                    pos += 2
                    return m
                }
            }
            pos += 1
        }
        return nil
    }

    mutating func parse(headerOnly: Bool) -> Bool {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return false }
        pos = 2
        parsing: while let marker = nextMarker() {
            if marker == 0xD9 { break }
            if marker == 0xD8 || marker == 0x01 { continue }
            guard pos + 2 <= data.count else { break }
            let length = u16(pos)
            guard length >= 2, pos + length <= data.count else { break }
            let s = pos + 2
            let e = pos + length
            pos = e
            switch marker {
            case 0xC0, 0xC1, 0xC2:
                if frameFound { continue }
                guard parseFrame(s, e, progressive: marker == 0xC2, allocate: !headerOnly) else { return false }
                if headerOnly { return true }
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                return false
            case 0xC4:
                guard parseHuffman(s, e) else { break parsing }
            case 0xDB:
                guard parseQuant(s, e) else { break parsing }
            case 0xDD:
                if e - s >= 2 { restartInterval = u16(s) }
            case 0xDA:
                guard frameFound, !headerOnly, let scan = parseScanHeader(s, e) else { break parsing }
                let ok = decodeScan(scan)
                scansDecoded += 1
                if !ok { break parsing }
            case 0xE1:
                parseExif(s, e)
            case 0xEE:
                if e - s >= 12, data[s] == 0x41, data[s + 1] == 0x64, data[s + 2] == 0x6F,
                   data[s + 3] == 0x62, data[s + 4] == 0x65 {
                    adobeTransform = Int(data[s + 11])
                }
            default:
                break
            }
        }
        return headerOnly ? false : frameFound
    }

    private mutating func parseFrame(_ s: Int, _ e: Int, progressive: Bool, allocate: Bool) -> Bool {
        guard e - s >= 6, data[s] == 8 else { return false }
        let h = u16(s + 1)
        let w = u16(s + 3)
        let n = Int(data[s + 5])
        guard w > 0, h > 0, n == 1 || n == 3 || n == 4, s + 6 + n * 3 <= e else { return false }
        guard w * h <= 1 << 28 else { return false }
        var comps: [JPEGComponent] = []
        for i in 0..<n {
            let p = s + 6 + i * 3
            let hv = Int(data[p + 1])
            let c = JPEGComponent(id: Int(data[p]), h: hv >> 4, v: hv & 15, tq: Int(data[p + 2] & 3))
            guard c.h >= 1, c.h <= 4, c.v >= 1, c.v <= 4 else { return false }
            comps.append(c)
        }
        hmax = comps.map(\.h).max() ?? 1
        vmax = comps.map(\.v).max() ?? 1
        mcusX = (w + 8 * hmax - 1) / (8 * hmax)
        mcusY = (h + 8 * vmax - 1) / (8 * vmax)
        var total = 0
        for i in comps.indices {
            comps[i].width = (w * comps[i].h + hmax - 1) / hmax
            comps[i].height = (h * comps[i].v + vmax - 1) / vmax
            comps[i].blocksPerLine = (comps[i].width + 7) / 8
            comps[i].blocksPerColumn = (comps[i].height + 7) / 8
            comps[i].stride = mcusX * comps[i].h
            comps[i].offset = total
            total += comps[i].stride * mcusY * comps[i].v * 64
        }
        width = w
        height = h
        components = comps
        self.progressive = progressive
        frameFound = true
        if allocate { coefficients = [Int16](repeating: 0, count: total) }
        return true
    }

    private mutating func parseQuant(_ s: Int, _ e: Int) -> Bool {
        var p = s
        while p < e {
            let precision = Int(data[p] >> 4)
            let id = Int(data[p] & 3)
            p += 1
            let size = precision == 0 ? 64 : 128
            guard p + size <= e else { return false }
            var table = [Int32](repeating: 1, count: 64)
            for i in 0..<64 {
                let value = precision == 0 ? Int32(data[p + i]) : Int32(data[p + i * 2]) << 8 | Int32(data[p + i * 2 + 1])
                table[JPEGTables.dezigzag[i]] = value
            }
            quant[id] = table
            p += size
        }
        return true
    }

    private mutating func parseHuffman(_ s: Int, _ e: Int) -> Bool {
        var p = s
        while p < e {
            let tableClass = Int(data[p] >> 4)
            let id = Int(data[p] & 3)
            p += 1
            guard tableClass < 2, p + 16 <= e else { return false }
            var counts = [Int](repeating: 0, count: 16)
            var total = 0
            for i in 0..<16 {
                counts[i] = Int(data[p + i])
                total += counts[i]
            }
            p += 16
            guard total <= 256, p + total <= e else { return false }
            let symbols = Array(data[p..<(p + total)])
            p += total
            guard let table = JPEGHuffman(counts: counts, symbols: symbols) else { return false }
            if tableClass == 0 { dcTables[id] = table } else { acTables[id] = table }
        }
        return true
    }

    private func parseScanHeader(_ s: Int, _ e: Int) -> JPEGScan? {
        guard e > s else { return nil }
        let n = Int(data[s])
        guard n >= 1, n <= 4, s + 1 + n * 2 + 3 <= e else { return nil }
        let p = s + 1 + n * 2
        var ss = Int(data[p])
        var se = Int(data[p + 1])
        let ah = Int(data[p + 2] >> 4)
        var al = Int(data[p + 2] & 15)
        let mode: JPEGScanMode
        if !progressive {
            mode = .baseline
            ss = 0
            se = 63
            al = 0
        } else {
            guard se <= 63, ss <= se, al <= 13 else { return nil }
            if ss == 0 {
                guard se == 0 else { return nil }
                mode = ah == 0 ? .dcFirst : .dcRefine
            } else {
                guard n == 1 else { return nil }
                mode = ah == 0 ? .acFirst : .acRefine
            }
        }
        let needsDC = mode == .baseline || mode == .dcFirst
        let needsAC = mode == .baseline || mode == .acFirst || mode == .acRefine
        guard let placeholder = JPEGHuffman(counts: [1] + [Int](repeating: 0, count: 15), symbols: [0]) else { return nil }
        var scan = JPEGScan(components: [], dc: [], ac: [], ss: ss, se: se, al: al, mode: mode)
        for i in 0..<n {
            let id = Int(data[s + 1 + i * 2])
            let tables = Int(data[s + 2 + i * 2])
            guard let index = components.firstIndex(where: { $0.id == id }) else { return nil }
            let dc = needsDC ? dcTables[(tables >> 4) & 3] : placeholder
            let ac = needsAC ? acTables[tables & 3] : placeholder
            guard let dc, let ac else { return nil }
            scan.components.append(index)
            scan.dc.append(dc)
            scan.ac.append(ac)
        }
        return scan
    }

    private mutating func decodeScan(_ scan: JPEGScan) -> Bool {
        var reader = JPEGBitReader(data: data, pos: pos)
        var coeffs = coefficients
        coefficients = []
        let comps = components
        let mx = mcusX
        let my = mcusY
        let interval = restartInterval
        let ok = coeffs.withUnsafeMutableBufferPointer { cb in
            JPEGTables.dezigzag.withUnsafeBufferPointer { zz in
                JPEGDecoder.runScan(scan, comps, mcusX: mx, mcusY: my, restartInterval: interval,
                                    reader: &reader, coefficients: cb.baseAddress!, zz: zz.baseAddress!)
            }
        }
        coefficients = coeffs
        pos = reader.pos
        return ok
    }

    private static func runScan(_ scan: JPEGScan, _ comps: [JPEGComponent], mcusX: Int, mcusY: Int,
                                restartInterval: Int, reader r: inout JPEGBitReader,
                                coefficients: UnsafeMutablePointer<Int16>, zz: UnsafePointer<Int>) -> Bool {
        var preds = [Int](repeating: 0, count: 4)
        var eobrun = 0
        let n = scan.components.count
        let total: Int
        if n == 1 {
            let c = comps[scan.components[0]]
            total = c.blocksPerLine * c.blocksPerColumn
        } else {
            total = mcusX * mcusY
        }
        var mcu = 0
        while mcu < total {
            if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
                r.restart()
                preds[0] = 0; preds[1] = 0; preds[2] = 0; preds[3] = 0
                eobrun = 0
            }
            if r.padding > 4096 { return true }
            if n == 1 {
                let c = comps[scan.components[0]]
                let by = mcu / c.blocksPerLine
                let bx = mcu - by * c.blocksPerLine
                let block = coefficients + c.offset + (by * c.stride + bx) * 64
                if !decodeBlock(scan.mode, &r, scan.dc[0], scan.ac[0], &preds[0], &eobrun,
                                scan.ss, scan.se, scan.al, zz, block) { return false }
            } else {
                let row = mcu / mcusX
                let col = mcu - row * mcusX
                for i in 0..<n {
                    let c = comps[scan.components[i]]
                    for v in 0..<c.v {
                        for h in 0..<c.h {
                            let block = coefficients + c.offset + ((row * c.v + v) * c.stride + col * c.h + h) * 64
                            if !decodeBlock(scan.mode, &r, scan.dc[i], scan.ac[i], &preds[i], &eobrun,
                                            scan.ss, scan.se, scan.al, zz, block) { return false }
                        }
                    }
                }
            }
            mcu += 1
        }
        return true
    }

    @inline(__always)
    private static func decodeBlock(_ mode: JPEGScanMode, _ r: inout JPEGBitReader, _ dc: JPEGHuffman, _ ac: JPEGHuffman,
                                    _ pred: inout Int, _ eobrun: inout Int, _ ss: Int, _ se: Int, _ al: Int,
                                    _ zz: UnsafePointer<Int>, _ block: UnsafeMutablePointer<Int16>) -> Bool {
        switch mode {
        case .baseline:
            let t = r.decode(dc)
            if t < 0 || t > 16 { return false }
            pred = pred &+ r.extend(t)
            block[0] = Int16(truncatingIfNeeded: pred)
            var k = 1
            while k < 64 {
                let rs = r.decode(ac)
                if rs < 0 { return false }
                let s = rs & 15
                let run = rs >> 4
                if s == 0 {
                    if run != 15 { break }
                    k += 16
                } else {
                    k += run
                    if k > 63 { return false }
                    block[zz[k]] = Int16(truncatingIfNeeded: r.extend(s))
                    k += 1
                }
            }
        case .dcFirst:
            let t = r.decode(dc)
            if t < 0 || t > 16 { return false }
            pred = pred &+ r.extend(t)
            block[0] = Int16(truncatingIfNeeded: pred &<< al)
        case .dcRefine:
            if r.bit() != 0 { block[0] |= Int16(truncatingIfNeeded: 1 << al) }
        case .acFirst:
            if eobrun > 0 {
                eobrun -= 1
                return true
            }
            var k = ss
            while k <= se {
                let rs = r.decode(ac)
                if rs < 0 { return false }
                let s = rs & 15
                let run = rs >> 4
                if s == 0 {
                    if run < 15 {
                        eobrun = (1 << run) - 1
                        if run > 0 { eobrun += r.bits(run) }
                        break
                    }
                    k += 16
                } else {
                    k += run
                    if k > 63 { return false }
                    block[zz[k]] = Int16(truncatingIfNeeded: r.extend(s) &* (1 << al))
                    k += 1
                }
            }
        case .acRefine:
            let p1 = Int16(truncatingIfNeeded: 1 << al)
            let m1 = 0 &- p1
            var k = ss
            if eobrun <= 0 {
                while k <= se {
                    let rs = r.decode(ac)
                    if rs < 0 { return false }
                    var run = rs >> 4
                    var value: Int16 = 0
                    if rs & 15 == 0 {
                        if run < 15 {
                            eobrun = 1 << run
                            if run > 0 { eobrun += r.bits(run) }
                            break
                        }
                    } else {
                        value = r.bit() != 0 ? p1 : m1
                    }
                    while k <= se {
                        let z = zz[k]
                        let c = block[z]
                        if c != 0 {
                            if r.bit() != 0 && (c & p1) == 0 { block[z] = c >= 0 ? c &+ p1 : c &+ m1 }
                        } else {
                            if run == 0 {
                                if value != 0 { block[z] = value }
                                k += 1
                                break
                            }
                            run -= 1
                        }
                        k += 1
                    }
                }
            }
            if eobrun > 0 {
                while k <= se {
                    let z = zz[k]
                    let c = block[z]
                    if c != 0 && r.bit() != 0 && (c & p1) == 0 { block[z] = c >= 0 ? c &+ p1 : c &+ m1 }
                    k += 1
                }
                eobrun -= 1
            }
        }
        return true
    }

    private mutating func parseExif(_ s: Int, _ e: Int) {
        guard e - s >= 14, data[s] == 0x45, data[s + 1] == 0x78, data[s + 2] == 0x69, data[s + 3] == 0x66,
              data[s + 4] == 0, data[s + 5] == 0 else { return }
        let t = s + 6
        let little: Bool
        if data[t] == 0x49 && data[t + 1] == 0x49 {
            little = true
        } else if data[t] == 0x4D && data[t + 1] == 0x4D {
            little = false
        } else {
            return
        }
        guard let ifd = tiff32(t, 4, e, little), let n = tiff16(t, ifd, e, little) else { return }
        for i in 0..<min(n, 512) {
            let entry = ifd + 2 + i * 12
            guard let tag = tiff16(t, entry, e, little) else { return }
            if tag == 0x0112 {
                if let type = tiff16(t, entry + 2, e, little), type == 3,
                   let value = tiff16(t, entry + 8, e, little), value >= 1, value <= 8 {
                    orientation = value
                }
                return
            }
        }
    }

    private func tiff16(_ base: Int, _ offset: Int, _ end: Int, _ little: Bool) -> Int? {
        let p = base + offset
        guard offset >= 0, p + 2 <= end else { return nil }
        let a = Int(data[p]), b = Int(data[p + 1])
        return little ? a | b << 8 : a << 8 | b
    }

    private func tiff32(_ base: Int, _ offset: Int, _ end: Int, _ little: Bool) -> Int? {
        guard let lo = tiff16(base, offset + (little ? 0 : 2), end, little),
              let hi = tiff16(base, offset + (little ? 2 : 0), end, little) else { return nil }
        return hi << 16 | lo
    }

    func render() -> [UInt8]? {
        guard frameFound, scansDecoded > 0, !coefficients.isEmpty else { return nil }
        var planes: [[UInt8]] = []
        var workspace = [Int32](repeating: 0, count: 64)
        coefficients.withUnsafeBufferPointer { coef in
            workspace.withUnsafeMutableBufferPointer { ws in
                for c in components {
                    let pw = c.blocksPerLine * 8
                    var plane = [UInt8](repeating: 0, count: pw * c.blocksPerColumn * 8)
                    plane.withUnsafeMutableBufferPointer { p in
                        quant[c.tq].withUnsafeBufferPointer { q in
                            for by in 0..<c.blocksPerColumn {
                                for bx in 0..<c.blocksPerLine {
                                    JPEGDecoder.idct(coef.baseAddress! + c.offset + (by * c.stride + bx) * 64,
                                                     q.baseAddress!, ws.baseAddress!,
                                                     p.baseAddress! + by * 8 * pw + bx * 8, pw)
                                }
                            }
                        }
                    }
                    planes.append(plane)
                }
            }
        }

        let transform: JPEGColorTransform
        switch components.count {
        case 1:
            transform = .gray
        case 3:
            if adobeTransform >= 0 {
                transform = adobeTransform == 0 ? .rgb : .ycc
            } else if components[0].id == 0x52 && components[1].id == 0x47 && components[2].id == 0x42 {
                transform = .rgb
            } else {
                transform = .ycc
            }
        default:
            transform = adobeTransform == 2 ? .ycck : .cmyk
        }

        let w = width
        let n = components.count
        var rgba = [UInt8](repeating: 255, count: w * height * 4)
        var rows = [UInt8](repeating: 0, count: w * n)
        var temp = [Int32](repeating: 0, count: (components.map(\.width).max() ?? 1) + 1)
        var maps: [[Int32]] = []
        for c in components {
            var map = [Int32](repeating: 0, count: w * 3)
            if c.h != hmax {
                for x in 0..<w {
                    let num = max(0, (2 * x + 1) * c.h - hmax)
                    let p = num * 256 / (2 * hmax)
                    let x0 = min(p >> 8, c.width - 1)
                    map[x * 3] = Int32(x0)
                    map[x * 3 + 1] = Int32(min(x0 + 1, c.width - 1))
                    map[x * 3 + 2] = Int32(p & 255)
                }
            }
            maps.append(map)
        }

        rgba.withUnsafeMutableBufferPointer { outBuffer in
            rows.withUnsafeMutableBufferPointer { rowBuffer in
                temp.withUnsafeMutableBufferPointer { tempBuffer in
                    let rowBase = rowBuffer.baseAddress!
                    let tmp = tempBuffer.baseAddress!
                    for y in 0..<height {
                        for i in 0..<n {
                            let c = components[i]
                            let pw = c.blocksPerLine * 8
                            let dst = rowBase + i * w
                            planes[i].withUnsafeBufferPointer { planeBuffer in
                                maps[i].withUnsafeBufferPointer { mapBuffer in
                                    JPEGDecoder.upsampleRow(planeBuffer.baseAddress!, pw, c, y, hmax: hmax, vmax: vmax,
                                                            width: w, map: mapBuffer.baseAddress!, temp: tmp, out: dst)
                                }
                            }
                        }
                        JPEGDecoder.convertRow(rowBase, w, transform, outBuffer.baseAddress! + y * w * 4)
                    }
                }
            }
        }
        return rgba
    }

    @inline(never)
    private static func upsampleRow(_ plane: UnsafePointer<UInt8>, _ pw: Int, _ c: JPEGComponent, _ y: Int,
                                    hmax: Int, vmax: Int, width: Int, map: UnsafePointer<Int32>,
                                    temp: UnsafeMutablePointer<Int32>, out: UnsafeMutablePointer<UInt8>) {
        if c.h == hmax && c.v == vmax {
            out.update(from: plane + y * pw, count: width)
            return
        }
        var y0 = min(y, c.height - 1)
        var y1 = y0
        var wy: Int32 = 0
        if c.v != vmax {
            let num = max(0, (2 * y + 1) * c.v - vmax)
            let p = num * 256 / (2 * vmax)
            y0 = min(p >> 8, c.height - 1)
            y1 = min(y0 + 1, c.height - 1)
            wy = Int32(p & 255)
        }
        let top = plane + y0 * pw
        let bottom = plane + y1 * pw
        let wt = 256 - wy
        for x in 0..<c.width {
            temp[x] = Int32(top[x]) &* wt &+ Int32(bottom[x]) &* wy
        }
        if c.h == hmax {
            for x in 0..<width { out[x] = UInt8(truncatingIfNeeded: (temp[x] &+ 128) >> 8) }
        } else {
            for x in 0..<width {
                let m = map + x * 3
                let wx = m[2]
                let v = temp[Int(m[0])] &* (256 &- wx) &+ temp[Int(m[1])] &* wx
                out[x] = UInt8(truncatingIfNeeded: (v &+ 32768) >> 16)
            }
        }
    }

    @inline(__always) private static func clamp(_ v: Int32) -> UInt8 {
        UInt8(truncatingIfNeeded: v < 0 ? 0 : (v > 255 ? 255 : v))
    }

    @inline(__always) private static func blend(_ a: Int32, _ b: Int32) -> UInt8 {
        let t = a &* b &+ 128
        return UInt8(truncatingIfNeeded: (t &+ (t >> 8)) >> 8)
    }

    @inline(never)
    private static func convertRow(_ rows: UnsafePointer<UInt8>, _ w: Int, _ transform: JPEGColorTransform,
                                   _ out: UnsafeMutablePointer<UInt8>) {
        switch transform {
        case .gray:
            for x in 0..<w {
                let g = rows[x]
                out[x * 4] = g
                out[x * 4 + 1] = g
                out[x * 4 + 2] = g
            }
        case .rgb:
            for x in 0..<w {
                out[x * 4] = rows[x]
                out[x * 4 + 1] = rows[w + x]
                out[x * 4 + 2] = rows[2 * w + x]
            }
        case .ycc, .ycck:
            let k = rows + 3 * w
            for x in 0..<w {
                let yy = Int32(rows[x]) << 16 | 32768
                let cb = Int32(rows[w + x]) &- 128
                let cr = Int32(rows[2 * w + x]) &- 128
                var r = clamp((yy &+ 91881 &* cr) >> 16)
                var g = clamp((yy &- 22554 &* cb &- 46802 &* cr) >> 16)
                var b = clamp((yy &+ 116130 &* cb) >> 16)
                if transform == .ycck {
                    let kk = Int32(k[x])
                    r = blend(255 &- Int32(r), kk)
                    g = blend(255 &- Int32(g), kk)
                    b = blend(255 &- Int32(b), kk)
                }
                out[x * 4] = r
                out[x * 4 + 1] = g
                out[x * 4 + 2] = b
            }
        case .cmyk:
            for x in 0..<w {
                let kk = Int32(rows[3 * w + x])
                out[x * 4] = blend(Int32(rows[x]), kk)
                out[x * 4 + 1] = blend(Int32(rows[w + x]), kk)
                out[x * 4 + 2] = blend(Int32(rows[2 * w + x]), kk)
            }
        }
    }

    @inline(__always)
    private static func idct1D(_ s0: Int32, _ s1: Int32, _ s2: Int32, _ s3: Int32,
                               _ s4: Int32, _ s5: Int32, _ s6: Int32, _ s7: Int32)
        -> (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) {
        var p1 = (s2 &+ s6) &* 2217
        var t2 = p1 &+ s6 &* -7567
        var t3 = p1 &+ s2 &* 3135
        var t0 = (s0 &+ s4) &<< 12
        var t1 = (s0 &- s4) &<< 12
        let x0 = t0 &+ t3
        let x3 = t0 &- t3
        let x1 = t1 &+ t2
        let x2 = t1 &- t2
        t0 = s7
        t1 = s5
        t2 = s3
        t3 = s1
        var p3 = t0 &+ t2
        var p4 = t1 &+ t3
        p1 = t0 &+ t3
        var p2 = t1 &+ t2
        let p5 = (p3 &+ p4) &* 4816
        t0 = t0 &* 1223
        t1 = t1 &* 8410
        t2 = t2 &* 12586
        t3 = t3 &* 6149
        p1 = p5 &+ p1 &* -3685
        p2 = p5 &+ p2 &* -10497
        p3 = p3 &* -8034
        p4 = p4 &* -1597
        t3 = t3 &+ p1 &+ p4
        t2 = t2 &+ p2 &+ p3
        t1 = t1 &+ p2 &+ p4
        t0 = t0 &+ p1 &+ p3
        return (x0, x1, x2, x3, t0, t1, t2, t3)
    }

    @inline(never)
    private static func idct(_ coef: UnsafePointer<Int16>, _ q: UnsafePointer<Int32>, _ ws: UnsafeMutablePointer<Int32>,
                             _ out: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        for i in 0..<8 {
            let d0 = Int32(coef[i]) &* q[i]
            let d1 = Int32(coef[i + 8]) &* q[i + 8]
            let d2 = Int32(coef[i + 16]) &* q[i + 16]
            let d3 = Int32(coef[i + 24]) &* q[i + 24]
            let d4 = Int32(coef[i + 32]) &* q[i + 32]
            let d5 = Int32(coef[i + 40]) &* q[i + 40]
            let d6 = Int32(coef[i + 48]) &* q[i + 48]
            let d7 = Int32(coef[i + 56]) &* q[i + 56]
            if d1 | d2 | d3 | d4 | d5 | d6 | d7 == 0 {
                let dc = d0 &<< 2
                for k in 0..<8 { ws[i + k * 8] = dc }
                continue
            }
            var (x0, x1, x2, x3, t0, t1, t2, t3) = idct1D(d0, d1, d2, d3, d4, d5, d6, d7)
            x0 = x0 &+ 512
            x1 = x1 &+ 512
            x2 = x2 &+ 512
            x3 = x3 &+ 512
            ws[i] = (x0 &+ t3) >> 10
            ws[i + 56] = (x0 &- t3) >> 10
            ws[i + 8] = (x1 &+ t2) >> 10
            ws[i + 48] = (x1 &- t2) >> 10
            ws[i + 16] = (x2 &+ t1) >> 10
            ws[i + 40] = (x2 &- t1) >> 10
            ws[i + 24] = (x3 &+ t0) >> 10
            ws[i + 32] = (x3 &- t0) >> 10
        }
        let bias: Int32 = 65536 + (128 << 17)
        for i in 0..<8 {
            let v = ws + i * 8
            var (x0, x1, x2, x3, t0, t1, t2, t3) = idct1D(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
            x0 = x0 &+ bias
            x1 = x1 &+ bias
            x2 = x2 &+ bias
            x3 = x3 &+ bias
            let o = out + i * stride
            o[0] = clamp((x0 &+ t3) >> 17)
            o[7] = clamp((x0 &- t3) >> 17)
            o[1] = clamp((x1 &+ t2) >> 17)
            o[6] = clamp((x1 &- t2) >> 17)
            o[2] = clamp((x2 &+ t1) >> 17)
            o[5] = clamp((x2 &- t1) >> 17)
            o[3] = clamp((x3 &+ t0) >> 17)
            o[4] = clamp((x3 &- t0) >> 17)
        }
    }
}

// MARK: - Encoding

private struct JPEGBitWriter {
    var out: [UInt8]
    var accumulator: UInt32 = 0
    var count = 0

    @inline(__always) mutating func write(_ code: Int, _ length: Int) {
        accumulator = (accumulator << UInt32(length)) | (UInt32(truncatingIfNeeded: code) & ((1 << UInt32(length)) - 1))
        count += length
        while count >= 8 {
            let byte = UInt8(truncatingIfNeeded: accumulator >> UInt32(count - 8))
            out.append(byte)
            if byte == 0xFF { out.append(0) }
            count -= 8
        }
    }

    mutating func flush() {
        if count > 0 { write(0x7F, 8 - count) }
    }
}

private struct JPEGHuffmanCodes {
    var codes = [Int](repeating: 0, count: 256)
    var sizes = [Int](repeating: 0, count: 256)

    init(bits: [Int], values: [UInt8]) {
        var code = 0
        var k = 0
        for length in 1...16 {
            for _ in 0..<bits[length - 1] {
                codes[Int(values[k])] = code
                sizes[Int(values[k])] = length
                code += 1
                k += 1
            }
            code <<= 1
        }
    }
}

private enum JPEGEncoder {
    static func encode(rgba: [UInt8], width: Int, height: Int, quality: Double) -> [UInt8] {
        guard width > 0, height > 0, width <= 65535, height <= 65535, rgba.count >= width * height * 4 else { return [] }
        let q = quality.isFinite ? min(max(quality, 0), 1) : 0.92
        let qi = max(1, min(100, Int((q * 100).rounded())))
        let scale = qi < 50 ? 5000 / qi : 200 - qi * 2
        let lumaQ = JPEGTables.lumaQuant.map { max(1, min(255, ($0 * scale + 50) / 100)) }
        let chromaQ = JPEGTables.chromaQuant.map { max(1, min(255, ($0 * scale + 50) / 100)) }
        let aan: [Float] = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]
        var lumaDivisors = [Float](repeating: 0, count: 64)
        var chromaDivisors = [Float](repeating: 0, count: 64)
        for row in 0..<8 {
            for col in 0..<8 {
                let f = aan[row] * aan[col] * 8
                lumaDivisors[row * 8 + col] = 1 / (Float(lumaQ[row * 8 + col]) * f)
                chromaDivisors[row * 8 + col] = 1 / (Float(chromaQ[row * 8 + col]) * f)
            }
        }
        let dcLuma = JPEGHuffmanCodes(bits: JPEGTables.dcLumaBits, values: JPEGTables.dcValues)
        let acLuma = JPEGHuffmanCodes(bits: JPEGTables.acLumaBits, values: JPEGTables.acLumaValues)
        let dcChroma = JPEGHuffmanCodes(bits: JPEGTables.dcChromaBits, values: JPEGTables.dcValues)
        let acChroma = JPEGHuffmanCodes(bits: JPEGTables.acChromaBits, values: JPEGTables.acChromaValues)

        var out: [UInt8] = []
        out.reserveCapacity(width * height / 2 + 1024)
        out += [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        out += [0xFF, 0xDB, 0, 132, 0]
        for i in 0..<64 { out.append(UInt8(lumaQ[JPEGTables.dezigzag[i]])) }
        out.append(1)
        for i in 0..<64 { out.append(UInt8(chromaQ[JPEGTables.dezigzag[i]])) }
        out += [0xFF, 0xC0, 0, 17, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3,
                1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        out += [0xFF, 0xC4, 0x01, 0xA2]
        for (tc, bits, values) in [(UInt8(0x00), JPEGTables.dcLumaBits, JPEGTables.dcValues),
                                   (0x10, JPEGTables.acLumaBits, JPEGTables.acLumaValues),
                                   (0x01, JPEGTables.dcChromaBits, JPEGTables.dcValues),
                                   (0x11, JPEGTables.acChromaBits, JPEGTables.acChromaValues)] {
            out.append(tc)
            out += bits.map { UInt8($0) }
            out += values
        }
        out += [0xFF, 0xDA, 0, 12, 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]

        var writer = JPEGBitWriter(out: out)
        out = []
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 256 * 3 + 64)
        let quantized = UnsafeMutablePointer<Int>.allocate(capacity: 64)
        defer {
            scratch.deallocate()
            quantized.deallocate()
        }
        let yBuf = scratch
        let cbBuf = scratch + 256
        let crBuf = scratch + 512
        let block = scratch + 768
        var dcY = 0
        var dcCb = 0
        var dcCr = 0
        rgba.withUnsafeBufferPointer { src in
            lumaDivisors.withUnsafeBufferPointer { ld in
                chromaDivisors.withUnsafeBufferPointer { cd in
                    JPEGTables.dezigzag.withUnsafeBufferPointer { zz in
                        let pixels = src.baseAddress!
                        for my in stride(from: 0, to: height, by: 16) {
                            for mx in stride(from: 0, to: width, by: 16) {
                                for py in 0..<16 {
                                    let row = pixels + min(my + py, height - 1) * width * 4
                                    for px in 0..<16 {
                                        let p = row + min(mx + px, width - 1) * 4
                                        let r = Float(p[0]), g = Float(p[1]), b = Float(p[2])
                                        let i = py * 16 + px
                                        yBuf[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128
                                        cbBuf[i] = -0.168736 * r - 0.331264 * g + 0.5 * b
                                        crBuf[i] = 0.5 * r - 0.418688 * g - 0.081312 * b
                                    }
                                }
                                for by in 0..<2 {
                                    for bx in 0..<2 {
                                        for r in 0..<8 {
                                            for c in 0..<8 { block[r * 8 + c] = yBuf[(by * 8 + r) * 16 + bx * 8 + c] }
                                        }
                                        encodeBlock(block, ld.baseAddress!, &dcY, dcLuma, acLuma, &writer, zz.baseAddress!, quantized)
                                    }
                                }
                                downsample(cbBuf, block)
                                encodeBlock(block, cd.baseAddress!, &dcCb, dcChroma, acChroma, &writer, zz.baseAddress!, quantized)
                                downsample(crBuf, block)
                                encodeBlock(block, cd.baseAddress!, &dcCr, dcChroma, acChroma, &writer, zz.baseAddress!, quantized)
                            }
                        }
                    }
                }
            }
        }
        writer.flush()
        out = writer.out
        out += [0xFF, 0xD9]
        return out
    }

    @inline(__always)
    private static func fdct(_ d: UnsafeMutablePointer<Float>, _ step: Int) {
        let d0 = d[0], d1 = d[step], d2 = d[2 * step], d3 = d[3 * step]
        let d4 = d[4 * step], d5 = d[5 * step], d6 = d[6 * step], d7 = d[7 * step]
        let tmp0 = d0 + d7, tmp7 = d0 - d7
        let tmp1 = d1 + d6, tmp6 = d1 - d6
        let tmp2 = d2 + d5, tmp5 = d2 - d5
        let tmp3 = d3 + d4, tmp4 = d3 - d4
        let tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3
        let tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2
        d[0] = tmp10 + tmp11
        d[4 * step] = tmp10 - tmp11
        let z1 = (tmp12 + tmp13) * 0.707106781
        d[2 * step] = tmp13 + z1
        d[6 * step] = tmp13 - z1
        let o10 = tmp4 + tmp5, o11 = tmp5 + tmp6, o12 = tmp6 + tmp7
        let z5 = (o10 - o12) * 0.382683433
        let z2 = o10 * 0.541196100 + z5
        let z4 = o12 * 1.306562965 + z5
        let z3 = o11 * 0.707106781
        let z11 = tmp7 + z3, z13 = tmp7 - z3
        d[5 * step] = z13 + z2
        d[3 * step] = z13 - z2
        d[step] = z11 + z4
        d[7 * step] = z11 - z4
    }

    @inline(__always)
    private static func downsample(_ plane: UnsafePointer<Float>, _ block: UnsafeMutablePointer<Float>) {
        for r in 0..<8 {
            for c in 0..<8 {
                let i = r * 32 + c * 2
                block[r * 8 + c] = (plane[i] + plane[i + 1] + plane[i + 16] + plane[i + 17]) * 0.25
            }
        }
    }

    private static func encodeBlock(_ d: UnsafeMutablePointer<Float>, _ divisors: UnsafePointer<Float>, _ prevDC: inout Int,
                                    _ dc: JPEGHuffmanCodes, _ ac: JPEGHuffmanCodes, _ writer: inout JPEGBitWriter,
                                    _ zz: UnsafePointer<Int>, _ q: UnsafeMutablePointer<Int>) {
        for r in 0..<8 { fdct(d + r * 8, 1) }
        for c in 0..<8 { fdct(d + c, 8) }
        for i in 0..<64 {
            let n = zz[i]
            let v = Int((d[n] * divisors[n]).rounded())
            q[i] = i == 0 ? max(-2047, min(2047, v)) : max(-1023, min(1023, v))
        }
        let diff = q[0] - prevDC
        prevDC = q[0]
        let dcCategory = bitLength(diff)
        writer.write(dc.codes[dcCategory], dc.sizes[dcCategory])
        if dcCategory > 0 { writer.write(diff < 0 ? diff - 1 : diff, dcCategory) }
        var run = 0
        for i in 1..<64 {
            let v = q[i]
            if v == 0 {
                run += 1
                continue
            }
            while run >= 16 {
                writer.write(ac.codes[0xF0], ac.sizes[0xF0])
                run -= 16
            }
            let category = bitLength(v)
            let symbol = run << 4 | category
            writer.write(ac.codes[symbol], ac.sizes[symbol])
            writer.write(v < 0 ? v - 1 : v, category)
            run = 0
        }
        if run > 0 { writer.write(ac.codes[0], ac.sizes[0]) }
    }

    @inline(__always) private static func bitLength(_ v: Int) -> Int {
        let a = v < 0 ? -v : v
        return Int.bitWidth - a.leadingZeroBitCount
    }
}
