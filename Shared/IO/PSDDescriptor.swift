import Foundation

/// Photoshop's generic way of storing settings — layer styles, smart
/// objects and some adjustments — as typed keys and values, read and written
/// as Photoshop does.
struct PSDDescriptor: Equatable {
    indirect enum Value: Equatable {
        case descriptor(PSDDescriptor)
        case list([Value])
        case double(Double)
        /// A number with its unit: `#Prc` percent, `#Pxl` pixels, `#Ang` degrees.
        case unit(String, Double)
        case text(String)
        case enumerated(type: String, value: String)
        case integer(Int32)
        case largeInteger(Int64)
        case bool(Bool)
        case rawData([UInt8])
        /// Where a file is, as Photoshop names one a filter reads.
        case path([UInt8])
        case unitFloats(String, [Double])
        /// A reference to one thing named by an enumerated value, as curves
        /// and levels name their channel: class, type and value.
        case enumReference(classID: String, type: String, value: String)
        /// An array of `count` objects, written as one descriptor of their
        /// values, as a custom warp's grid is. Read back as `descriptor`.
        case objectArray(count: Int, PSDDescriptor)
        /// Kinds kept only so they can be skipped.
        case unsupported

        var descriptor: PSDDescriptor? { if case .descriptor(let value) = self { value } else { nil } }
        var list: [Value]? { if case .list(let value) = self { value } else { nil } }
        var text: String? { if case .text(let value) = self { value } else { nil } }
        var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
        var enumValue: String? { if case .enumerated(_, let value) = self { value } else { nil } }

        /// A path's file name: after "txtu", the length and the number of
        /// characters, little-endian, then the characters in UTF-16.
        var fileName: String? {
            guard case .path(let bytes) = self, bytes.count >= 12, bytes[0..<4].elementsEqual("txtu".utf8) else { return nil }
            let count = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
            let units = stride(from: 12, to: min(12 + count * 2, bytes.count - 1), by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            let path = String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return path.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init)
        }

        /// A path to a file by its name alone.
        static func path(named name: String) -> Value {
            let units = Array((name + "\0").utf16)
            var bytes = Array("txtu".utf8)
            for value in [8 + units.count * 2, units.count] {
                bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
            }
            for unit in units { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            return .path(bytes)
        }

        /// Any number, whatever its unit.
        var number: Double? {
            switch self {
            case .double(let value), .unit(_, let value): return value
            case .integer(let value): return Double(value)
            case .largeInteger(let value): return Double(value)
            default: return nil
            }
        }
    }

    var classID: String
    var name = ""
    var items: [(key: String, value: Value)] = []

    init(classID: String, name: String = "", items: [(key: String, value: Value)] = []) {
        self.classID = classID
        self.name = name
        self.items = items
    }

    /// Whether it holds no settings at all.
    var isEmpty: Bool { items.isEmpty }

    subscript(key: String) -> Value? {
        items.first { $0.key == key }?.value
    }

    static func == (lhs: PSDDescriptor, rhs: PSDDescriptor) -> Bool {
        lhs.classID == rhs.classID && lhs.items.map(\.key) == rhs.items.map(\.key)
            && zip(lhs.items, rhs.items).allSatisfy { $0.value == $1.value }
    }

    // MARK: - Reading

    static func read(_ reader: inout BigEndianReader) throws -> PSDDescriptor {
        try read(&reader, depth: 0)
    }

    /// Deeper than Photoshop nests anything: a damaged file, which would
    /// otherwise run out of stack.
    private static let maximumDepth = 64

    private static func read(_ reader: inout BigEndianReader, depth: Int) throws -> PSDDescriptor {
        guard depth < maximumDepth else { throw PSDReader.Failure.damaged }
        let name = try readUnicode(&reader)
        let classID = try readKey(&reader)
        let count = Int(try reader.uint32())
        var items: [(key: String, value: Value)] = []
        for _ in 0..<count {
            let key = try readKey(&reader)
            let type = try reader.ascii(4)
            items.append((key, try readValue(&reader, type: type, depth: depth + 1)))
        }
        return PSDDescriptor(classID: classID, name: name, items: items)
    }

    private static func readKey(_ reader: inout BigEndianReader) throws -> String {
        let length = Int(try reader.uint32())
        return try reader.ascii(length == 0 ? 4 : length)
    }

    private static func readUnicode(_ reader: inout BigEndianReader) throws -> String {
        let count = Int(try reader.uint32())
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try reader.uint16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func readDouble(_ reader: inout BigEndianReader) throws -> Double {
        Double(bitPattern: try reader.uint64())
    }

    private static func readValue(_ reader: inout BigEndianReader, type: String, depth: Int) throws -> Value {
        guard depth < maximumDepth else { throw PSDReader.Failure.damaged }
        switch type {
        case "Objc", "GlbO":
            return .descriptor(try read(&reader, depth: depth))
        case "VlLs":
            let count = Int(try reader.uint32())
            var values: [Value] = []
            for _ in 0..<count {
                let itemType = try reader.ascii(4)
                values.append(try readValue(&reader, type: itemType, depth: depth + 1))
            }
            return .list(values)
        case "doub":
            return .double(try readDouble(&reader))
        case "UntF":
            let unit = try reader.ascii(4)
            return .unit(unit, try readDouble(&reader))
        case "TEXT":
            return .text(try readUnicode(&reader))
        case "enum":
            let type = try readKey(&reader)
            return .enumerated(type: type, value: try readKey(&reader))
        case "long":
            return .integer(try reader.int32())
        case "comp":
            return .largeInteger(Int64(bitPattern: try reader.uint64()))
        case "bool":
            return .bool(try reader.uint8() != 0)
        case "type", "GlbC":
            _ = try readUnicode(&reader)
            _ = try readKey(&reader)
            return .unsupported
        case "tdta", "alis":
            let length = Int(try reader.uint32())
            return .rawData(try reader.bytes(length))
        case "Pth ":
            let length = Int(try reader.uint32())
            return .path(try reader.bytes(length))
        case "UnFl":
            let unit = try reader.ascii(4)
            let count = Int(try reader.uint32())
            var values: [Double] = []
            for _ in 0..<count { values.append(try readDouble(&reader)) }
            return .unitFloats(unit, values)
        case "ObAr":
            // An array of objects, kept as one descriptor of their values.
            _ = try reader.uint32()
            return .descriptor(try read(&reader, depth: depth))
        case "obj ":
            let count = Int(try reader.uint32())
            var reference: Value = .unsupported
            for _ in 0..<count {
                switch try reader.ascii(4) {
                case "Enmr":
                    _ = try readUnicode(&reader)
                    let classID = try readKey(&reader)
                    let type = try readKey(&reader)
                    let value = try readKey(&reader)
                    if count == 1 { reference = .enumReference(classID: classID, type: type, value: value) }
                case "Clss":
                    _ = try readUnicode(&reader)
                    _ = try readKey(&reader)
                case "Idnt", "indx", "rele":
                    _ = try reader.uint32()
                case "name":
                    _ = try readUnicode(&reader)
                    _ = try readKey(&reader)
                    _ = try readUnicode(&reader)
                case "prop":
                    _ = try readUnicode(&reader)
                    _ = try readKey(&reader)
                    _ = try readKey(&reader)
                default:
                    throw PSDReader.Failure.damaged
                }
            }
            return reference
        default:
            throw PSDReader.Failure.unsupported
        }
    }

    // MARK: - Writing

    func write(to writer: inout PSDBinaryWriter) {
        writer.unicodeString(name)
        Self.writeKey(classID, to: &writer)
        writer.uint32(items.count)
        for item in items {
            Self.writeKey(item.key, to: &writer)
            Self.writeValue(item.value, to: &writer)
        }
    }

    /// Four-character keys are written bare; longer ones with a length.
    private static func writeKey(_ key: String, to writer: inout PSDBinaryWriter) {
        let bytes = Array(key.utf8)
        if bytes.count == 4 {
            writer.uint32(0)
        } else {
            writer.uint32(bytes.count)
        }
        writer.bytes(bytes)
    }

    private static func writeValue(_ value: Value, to writer: inout PSDBinaryWriter) {
        switch value {
        case .descriptor(let descriptor):
            writer.ascii("Objc")
            descriptor.write(to: &writer)
        case .list(let values):
            writer.ascii("VlLs")
            writer.uint32(values.count)
            for value in values { writeValue(value, to: &writer) }
        case .double(let value):
            writer.ascii("doub")
            writer.float64(value)
        case .unit(let unit, let value):
            writer.ascii("UntF")
            writer.ascii(unit)
            writer.float64(value)
        case .text(let text):
            writer.ascii("TEXT")
            writer.unicodeString(text)
        case .enumerated(let type, let value):
            writer.ascii("enum")
            writeKey(type, to: &writer)
            writeKey(value, to: &writer)
        case .integer(let value):
            writer.ascii("long")
            writer.int32(Int(value))
        case .largeInteger(let value):
            writer.ascii("comp")
            writer.uint64(Int(value))
        case .bool(let value):
            writer.ascii("bool")
            writer.uint8(value ? 1 : 0)
        case .rawData(let bytes):
            writer.ascii("tdta")
            writer.uint32(bytes.count)
            writer.bytes(bytes)
        case .path(let bytes):
            writer.ascii("Pth ")
            writer.uint32(bytes.count)
            writer.bytes(bytes)
        case .unitFloats(let unit, let values):
            writer.ascii("UnFl")
            writer.ascii(unit)
            writer.uint32(values.count)
            for value in values { writer.float64(value) }
        case .objectArray(let count, let descriptor):
            writer.ascii("ObAr")
            writer.uint32(count)
            descriptor.write(to: &writer)
        case .enumReference(let classID, let type, let value):
            writer.ascii("obj ")
            writer.uint32(1)
            writer.ascii("Enmr")
            writer.unicodeString("")
            writeKey(classID, to: &writer)
            writeKey(type, to: &writer)
            writeKey(value, to: &writer)
        case .unsupported:
            // Nothing Easel writes is of a kind it cannot read.
            break
        }
    }

    /// The descriptor with its version in front, as tagged blocks hold it.
    var versionedBytes: [UInt8] {
        var writer = PSDBinaryWriter()
        writer.uint32(16)
        write(to: &writer)
        return writer.data
    }
}

extension BigEndianReader {
    init(bytes: [UInt8]) {
        self.init(Data(bytes))
    }
}

extension PSDDescriptor.Value {
    /// An RGB colour as Photoshop keeps one, channels 0...255.
    static func rgb(_ color: RGBAColor) -> PSDDescriptor.Value {
        func channel(_ value: Double) -> Double { min(max(value, 0), 1) * 255 }
        return .descriptor(PSDDescriptor(classID: "RGBC", items: [
            ("Rd  ", .double(channel(color.red))), ("Grn ", .double(channel(color.green))), ("Bl  ", .double(channel(color.blue))),
        ]))
    }

    /// The colour of an RGB (or grey) colour descriptor.
    var color: RGBAColor? {
        guard let descriptor else { return nil }
        if let red = descriptor["Rd  "]?.number, let green = descriptor["Grn "]?.number, let blue = descriptor["Bl  "]?.number {
            return RGBAColor(red: red / 255, green: green / 255, blue: blue / 255)
        }
        if let cyan = descriptor["Cyn "]?.number, let magenta = descriptor["Mgnt"]?.number,
           let yellow = descriptor["Ylw "]?.number, let black = descriptor["Blck"]?.number {
            // Plainly, without a press's profile.
            let k = 1 - black / 100
            return RGBAColor(red: (1 - cyan / 100) * k, green: (1 - magenta / 100) * k, blue: (1 - yellow / 100) * k)
        }
        if let grey = descriptor["Gry "]?.number {
            let value = 1 - grey / 100
            return RGBAColor(red: value, green: value, blue: value)
        }
        return nil
    }
}
