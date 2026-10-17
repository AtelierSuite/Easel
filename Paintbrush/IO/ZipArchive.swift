import Compression
import Foundation
import zlib

package enum ZipError: LocalizedError {
    case notAnArchive
    case unsupportedCompression(UInt16)
    case corruptEntry(String)
    case decompressionFailed(String)
    /// An OLE compound document rather than a ZIP.
    case protectedOrLegacyWorkbook
    case encryptedEntry(String)

    package var errorDescription: String? {
        String(localized: "Error.DocumentDamaged")
    }
}

/// A minimal ZIP reader and writer, as used for documents saved as
/// single-file packages such as Pixelmator Pro's: stored and deflated
/// entries, no encryption, no spanning. Shared with Tables.
///
/// An archive can be written back with some entries replaced and the rest
/// copied through byte for byte, compressed data and headers as they were.
package enum ZipArchive {

    // MARK: - Format constants

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50

    /// Header id of the ZIP64 extended information extra field.
    private static let zip64ExtraFieldID: UInt16 = 0x0001

    /// The value a 32-bit size or offset carries when the real one lives in the
    /// ZIP64 extra field instead.
    private static let zip64Placeholder: UInt32 = 0xFFFF_FFFF

    /// OLE compound file signature, which is what password-protected and legacy
    /// `.xls` workbooks start with.
    private static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// A ceiling on how much we will allocate for one inflated entry, so a
    /// damaged or hostile header can't ask us to reserve gigabytes.
    private static let maximumInflatedSize = 512 * 1024 * 1024

    // MARK: - Reading

    /// Reads every entry into a path-keyed table.
    package static func entries(in data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in try rawEntries(in: data) where !entry.isDirectory {
            result[entry.name] = try entry.contents()
        }
        guard !result.isEmpty else { throw ZipError.notAnArchive }
        return result
    }

    /// Reads the one entry at `path`, or nil if there is none, found
    /// through the central directory without inflating any other. Given
    /// mapped data, only the pages that entry and the directory lie on are
    /// read from disk.
    package static func entry(named path: String, in data: Data) throws -> Data? {
        let bytes = zeroBased(data)
        guard let directoryStart = locateCentralDirectory(bytes) else { throw ZipError.notAnArchive }
        var offset = directoryStart
        while offset + 46 <= bytes.count, readUInt32(bytes, offset) == centralDirectorySignature {
            let record = try directoryRecord(bytes, at: offset)
            if record.name == path {
                guard record.flags & 1 == 0 else { throw ZipError.encryptedEntry(record.name) }
                return try entry(bytes, record: record).contents()
            }
            offset += record.length
        }
        return nil
    }

    /// The file at `url`, mapped rather than read, for `entry(named:in:)`.
    package static func mappedFile(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// Data whose indices start at zero, as the reading below counts them.
    private static func zeroBased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }

    /// One entry as the archive keeps it: its compressed bytes untouched and
    /// everything its headers say, so an archive can be written again with
    /// only some entries replaced and the rest copied through as they were.
    package struct Entry: Equatable {
        package var name: String
        package var method: UInt16
        package var flags: UInt16 = 0
        package var crc: UInt32
        package var uncompressedSize: Int
        package var versionMadeBy: UInt16 = 20
        /// The version a reader needs, as the entry came; ZIP64 raises it.
        package var versionNeeded: UInt16 = 20
        package var modificationTime: UInt16
        package var modificationDate: UInt16
        package var internalAttributes: UInt16 = 0
        package var externalAttributes: UInt32 = 0
        /// Extra fields from the local and central headers, less the ZIP64
        /// field, which is written afresh from the real sizes.
        package var localExtra = Data()
        package var centralExtra = Data()
        package var comment = Data()
        /// The entry's bytes as stored: deflated when `method` is 8.
        package var payload: Data

        package var isDirectory: Bool { name.hasSuffix("/") }

        /// A new entry holding `contents`, stored, or deflated when asked
        /// and that makes it smaller.
        package init(name: String, contents: Data, deflate: Bool = false, date: Date = Date()) {
            self.name = name
            crc = ZipArchive.crc32(contents)
            uncompressedSize = contents.count
            (modificationTime, modificationDate) = ZipArchive.dosTime(date)
            if deflate, !contents.isEmpty, let deflated = ZipArchive.deflate(contents), deflated.count < contents.count {
                method = 8
                payload = deflated
            } else {
                method = 0
                payload = contents
            }
            // Bit 11: the name is UTF-8.
            if name.utf8.contains(where: { $0 >= 0x80 }) { flags |= 1 << 11 }
        }

        fileprivate init(record: DirectoryRecord, localExtra: Data, payload: Data) {
            name = record.name
            method = record.method
            // Sizes and CRC go in the local header when written again, so a
            // trailing data descriptor (bit 3) is never needed.
            flags = record.flags & ~(1 << 3)
            crc = record.crc
            uncompressedSize = record.uncompressedSize
            versionMadeBy = record.versionMadeBy
            versionNeeded = record.versionNeeded
            modificationTime = record.modificationTime
            modificationDate = record.modificationDate
            internalAttributes = record.internalAttributes
            externalAttributes = record.externalAttributes
            self.localExtra = localExtra
            centralExtra = record.extra
            comment = record.comment
            self.payload = payload
        }

        /// The entry's bytes, inflated and checked against its CRC.
        package func contents() throws -> Data {
            let content: Data
            switch method {
            case 0:
                content = payload
            case 8:
                // An entry that deflates to nothing decodes to zero bytes, which the
                // Compression framework reports the same way it reports failure. A
                // zero size with a real CRC means the writer just omitted the size.
                if uncompressedSize == 0, crc == 0 {
                    content = Data()
                } else if let inflated = ZipArchive.inflate(payload, expectedSize: uncompressedSize) {
                    content = inflated
                } else {
                    throw ZipError.decompressionFailed(name)
                }
            default:
                throw ZipError.unsupportedCompression(method)
            }

            // The CRC is the only thing that catches a stream which merely stopped
            // early: a truncated DEFLATE body still decodes, just to fewer bytes.
            guard ZipArchive.crc32(content) == crc else { throw ZipError.corruptEntry(name) }
            return content
        }
    }

    /// Every entry, folders included, in the central directory's order.
    package static func rawEntries(in data: Data) throws -> [Entry] {
        let bytes = zeroBased(data)
        guard !bytes.starts(with: compoundFileSignature) else { throw ZipError.protectedOrLegacyWorkbook }
        guard let directoryStart = locateCentralDirectory(bytes) else { throw ZipError.notAnArchive }

        var result: [Entry] = []
        var offset = directoryStart
        while offset + 46 <= bytes.count, readUInt32(bytes, offset) == centralDirectorySignature {
            let record = try directoryRecord(bytes, at: offset)

            // Bit 0 of the general purpose flags means the entry's bytes are
            // encrypted; decompressing them anyway would yield noise.
            guard record.flags & 1 == 0 else { throw ZipError.encryptedEntry(record.name) }

            result.append(try entry(bytes, record: record))
            offset += record.length
        }
        guard !result.isEmpty else { throw ZipError.notAnArchive }
        return result
    }

    /// Everything one central directory record says about a single entry.
    fileprivate struct DirectoryRecord {
        var name: String
        var versionMadeBy: UInt16
        var versionNeeded: UInt16
        var flags: UInt16
        var method: UInt16
        var modificationTime: UInt16
        var modificationDate: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var internalAttributes: UInt16
        var externalAttributes: UInt32
        var localHeaderOffset: Int
        var extra: Data
        var comment: Data
        /// Byte length of the record itself, for walking to the next one.
        var length: Int
    }

    private static func directoryRecord(_ bytes: Data, at offset: Int) throws -> DirectoryRecord {
        let nameLength = Int(readUInt16(bytes, offset + 28))
        let extraLength = Int(readUInt16(bytes, offset + 30))
        let commentLength = Int(readUInt16(bytes, offset + 32))

        guard offset + 46 + nameLength + extraLength + commentLength <= bytes.count else { throw ZipError.notAnArchive }
        let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
        let extraRange = (offset + 46 + nameLength)..<(offset + 46 + nameLength + extraLength)
        let commentStart = extraRange.upperBound

        let compressed = readUInt32(bytes, offset + 20)
        let uncompressed = readUInt32(bytes, offset + 24)
        let localOffset = readUInt32(bytes, offset + 42)

        var record = DirectoryRecord(
            name: name,
            versionMadeBy: readUInt16(bytes, offset + 4),
            versionNeeded: readUInt16(bytes, offset + 6),
            flags: readUInt16(bytes, offset + 8),
            method: readUInt16(bytes, offset + 10),
            modificationTime: readUInt16(bytes, offset + 12),
            modificationDate: readUInt16(bytes, offset + 14),
            crc: readUInt32(bytes, offset + 16),
            compressedSize: Int(compressed),
            uncompressedSize: Int(uncompressed),
            internalAttributes: readUInt16(bytes, offset + 36),
            externalAttributes: readUInt32(bytes, offset + 38),
            localHeaderOffset: Int(localOffset),
            extra: withoutZip64Field(bytes, in: extraRange),
            comment: Data(bytes[commentStart..<(commentStart + commentLength)]),
            length: 46 + nameLength + extraLength + commentLength
        )

        if compressed == zip64Placeholder || uncompressed == zip64Placeholder || localOffset == zip64Placeholder {
            guard var cursor = zip64ExtraField(bytes, in: extraRange) else { throw ZipError.corruptEntry(name) }

            // The field carries only the saturated values, always in this order.
            if uncompressed == zip64Placeholder {
                record.uncompressedSize = try readZip64Value(bytes, at: &cursor, name: name)
            }
            if compressed == zip64Placeholder {
                record.compressedSize = try readZip64Value(bytes, at: &cursor, name: name)
            }
            if localOffset == zip64Placeholder {
                record.localHeaderOffset = try readZip64Value(bytes, at: &cursor, name: name)
            }
        }
        return record
    }

    /// An extra field block with its ZIP64 field taken out.
    private static func withoutZip64Field(_ bytes: Data, in range: Range<Int>) -> Data {
        var kept = Data()
        var offset = range.lowerBound
        while offset + 4 <= range.upperBound {
            let identifier = readUInt16(bytes, offset)
            let end = min(offset + 4 + Int(readUInt16(bytes, offset + 2)), range.upperBound)
            if identifier != zip64ExtraFieldID { kept.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        return kept
    }

    /// Locates the body of the ZIP64 extended information field inside an extra
    /// field block, returning a cursor over its 64-bit values.
    private static func zip64ExtraField(_ bytes: Data, in range: Range<Int>) -> Zip64Cursor? {
        var offset = range.lowerBound
        while offset + 4 <= range.upperBound {
            let identifier = readUInt16(bytes, offset)
            let size = Int(readUInt16(bytes, offset + 2))
            let body = (offset + 4)..<min(offset + 4 + size, range.upperBound)
            if identifier == zip64ExtraFieldID { return Zip64Cursor(offset: body.lowerBound, end: body.upperBound) }
            offset += 4 + size
        }
        return nil
    }

    /// Walks the fixed-order 64-bit values of a ZIP64 extended information field.
    private struct Zip64Cursor {
        var offset: Int
        let end: Int
    }

    private static func readZip64Value(_ bytes: Data, at cursor: inout Zip64Cursor, name: String) throws -> Int {
        guard cursor.offset + 8 <= cursor.end else { throw ZipError.corruptEntry(name) }
        let value = readUInt64(bytes, cursor.offset)
        guard value <= UInt64(Int.max) else { throw ZipError.corruptEntry(name) }
        cursor.offset += 8
        return Int(value)
    }

    private static func entry(_ bytes: Data, record: DirectoryRecord) throws -> Entry {
        let name = record.name
        // Compared against what is left, as a ZIP64 offset or size can be
        // large enough to overflow when added.
        guard record.localHeaderOffset >= 0, record.localHeaderOffset <= bytes.count - 30,
              readUInt32(bytes, record.localHeaderOffset) == localHeaderSignature else {
            throw ZipError.corruptEntry(name)
        }
        let nameLength = Int(readUInt16(bytes, record.localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, record.localHeaderOffset + 28))
        let extraStart = record.localHeaderOffset + 30 + nameLength
        let start = extraStart + extraLength
        guard record.compressedSize >= 0, start <= bytes.count, record.compressedSize <= bytes.count - start else {
            throw ZipError.corruptEntry(name)
        }
        return Entry(
            record: record, localExtra: withoutZip64Field(bytes, in: extraStart..<start),
            payload: Data(bytes[start..<(start + record.compressedSize)])
        )
    }

    /// Scans backwards for the end-of-central-directory record, preferring the
    /// ZIP64 record behind it when the archive has one.
    private static func locateCentralDirectory(_ bytes: Data) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        var offset = bytes.count - 22
        while offset >= lowerBound {
            if readUInt32(bytes, offset) == endOfCentralDirectorySignature {
                if let zip64Start = zip64CentralDirectoryStart(bytes, endOfCentralDirectory: offset) {
                    return zip64Start
                }
                let start = readUInt32(bytes, offset + 16)
                // A saturated offset with no usable ZIP64 record behind it is a lie.
                guard start != zip64Placeholder else { return nil }
                return Int(start)
            }
            offset -= 1
        }
        return nil
    }

    /// Follows the ZIP64 locator that sits immediately before the classic
    /// end-of-central-directory record.
    private static func zip64CentralDirectoryStart(_ bytes: Data, endOfCentralDirectory: Int) -> Int? {
        let locator = endOfCentralDirectory - 20
        guard locator >= 0, readUInt32(bytes, locator) == zip64LocatorSignature else { return nil }

        guard let record = offsetWithin(bytes, readUInt64(bytes, locator + 8)),
              record + 56 <= bytes.count,
              readUInt32(bytes, record) == zip64EndOfCentralDirectorySignature else { return nil }
        return offsetWithin(bytes, readUInt64(bytes, record + 48))
    }

    private static func offsetWithin(_ bytes: Data, _ value: UInt64) -> Int? {
        guard value <= UInt64(bytes.count) else { return nil }
        return Int(value)
    }

    // MARK: - Writing

    /// An archive holding `entries` in this order. Sizes and offsets past
    /// what 32 bits hold are written as ZIP64, as is everything when
    /// `forceZip64` is set, which is only for testing.
    package static func archive(_ entries: [Entry], forceZip64: Bool = false) -> Data {
        var data = Data()
        var central = Data()
        for entry in entries {
            let offset = data.count
            let needsSizes = forceZip64 || entry.payload.count >= Int(zip64Placeholder)
                || entry.uncompressedSize >= Int(zip64Placeholder)
            let needsOffset = forceZip64 || offset >= Int(zip64Placeholder)
            let name = Data(entry.name.utf8)
            // ZIP64 needs version 4.5 to extract.
            let versionNeeded = needsSizes || needsOffset ? max(entry.versionNeeded, 45) : entry.versionNeeded

            // Local header: both sizes go to the ZIP64 field together, or neither.
            var localExtra = Data()
            if needsSizes {
                localExtra.appendUInt16(zip64ExtraFieldID)
                localExtra.appendUInt16(16)
                localExtra.appendUInt64(UInt64(entry.uncompressedSize))
                localExtra.appendUInt64(UInt64(entry.payload.count))
            }
            localExtra += entry.localExtra
            data.appendUInt32(localHeaderSignature)
            // No data descriptor follows: the sizes are in the header.
            let flags = entry.flags & ~(1 << 3)
            data.appendUInt16(versionNeeded)
            data.appendUInt16(flags)
            data.appendUInt16(entry.method)
            data.appendUInt16(entry.modificationTime)
            data.appendUInt16(entry.modificationDate)
            data.appendUInt32(entry.crc)
            data.appendUInt32(needsSizes ? zip64Placeholder : UInt32(entry.payload.count))
            data.appendUInt32(needsSizes ? zip64Placeholder : UInt32(entry.uncompressedSize))
            data.appendUInt16(UInt16(name.count))
            data.appendUInt16(UInt16(localExtra.count))
            data += name
            data += localExtra
            data += entry.payload

            // Central record: only the saturated values, in the fixed order.
            var zip64 = Data()
            if needsSizes {
                zip64.appendUInt64(UInt64(entry.uncompressedSize))
                zip64.appendUInt64(UInt64(entry.payload.count))
            }
            if needsOffset { zip64.appendUInt64(UInt64(offset)) }
            var centralExtra = Data()
            if !zip64.isEmpty {
                centralExtra.appendUInt16(zip64ExtraFieldID)
                centralExtra.appendUInt16(UInt16(zip64.count))
                centralExtra += zip64
            }
            centralExtra += entry.centralExtra
            central.appendUInt32(centralDirectorySignature)
            central.appendUInt16(entry.versionMadeBy)
            central.appendUInt16(versionNeeded)
            central.appendUInt16(flags)
            central.appendUInt16(entry.method)
            central.appendUInt16(entry.modificationTime)
            central.appendUInt16(entry.modificationDate)
            central.appendUInt32(entry.crc)
            central.appendUInt32(needsSizes ? zip64Placeholder : UInt32(entry.payload.count))
            central.appendUInt32(needsSizes ? zip64Placeholder : UInt32(entry.uncompressedSize))
            central.appendUInt16(UInt16(name.count))
            central.appendUInt16(UInt16(centralExtra.count))
            central.appendUInt16(UInt16(entry.comment.count))
            central.appendUInt16(0)
            central.appendUInt16(entry.internalAttributes)
            central.appendUInt32(entry.externalAttributes)
            central.appendUInt32(needsOffset ? zip64Placeholder : UInt32(offset))
            central += name
            central += centralExtra
            central += entry.comment
        }

        let directoryOffset = data.count
        data += central
        let needsZip64 = forceZip64 || entries.count >= 0xFFFF || directoryOffset >= Int(zip64Placeholder)
            || central.count >= Int(zip64Placeholder)
        if needsZip64 {
            let recordOffset = data.count
            data.appendUInt32(zip64EndOfCentralDirectorySignature)
            data.appendUInt64(44)
            data.appendUInt16(45)
            data.appendUInt16(45)
            data.appendUInt32(0)
            data.appendUInt32(0)
            data.appendUInt64(UInt64(entries.count))
            data.appendUInt64(UInt64(entries.count))
            data.appendUInt64(UInt64(central.count))
            data.appendUInt64(UInt64(directoryOffset))
            data.appendUInt32(zip64LocatorSignature)
            data.appendUInt32(0)
            data.appendUInt64(UInt64(recordOffset))
            data.appendUInt32(1)
        }
        data.appendUInt32(endOfCentralDirectorySignature)
        data.appendUInt16(0)
        data.appendUInt16(0)
        let count = needsZip64 ? UInt16(0xFFFF) : UInt16(entries.count)
        data.appendUInt16(count)
        data.appendUInt16(count)
        data.appendUInt32(needsZip64 ? zip64Placeholder : UInt32(central.count))
        data.appendUInt32(needsZip64 ? zip64Placeholder : UInt32(directoryOffset))
        data.appendUInt16(0)
        return data
    }

    /// MS-DOS time and date, which is how ZIP keeps when an entry changed.
    package static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(0, (parts.year ?? 1980) - 1980)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(min(year, 127) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    // MARK: - DEFLATE

    /// ZIP stores raw DEFLATE streams, which is exactly `COMPRESSION_ZLIB` here.
    ///
    /// A `nil` result means the decoder produced nothing usable. Output that is
    /// merely short — a truncated stream — still comes back here; the caller's
    /// CRC check is what rejects it.
    fileprivate static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        // The central directory usually tells us the exact output size, but a
        // damaged header can name an absurd one, so don't reserve it blindly.
        if expectedSize > 0, expectedSize <= maximumInflatedSize,
           let exact = decode(data, into: expectedSize), exact.count == expectedSize {
            return exact
        }
        // Otherwise grow the buffer until the output fits with room to spare,
        // which is how we know the buffer, not the stream, ended it.
        var capacity = max(min(data.count, maximumInflatedSize / 8) * 8, 64 * 1024)
        while capacity <= maximumInflatedSize {
            if let decoded = decode(data, into: capacity), decoded.count < capacity {
                return decoded
            }
            capacity *= 4
        }
        return nil
    }

    private static func decode(_ data: Data, into capacity: Int) -> Data? {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    /// Raw DEFLATE, or nil when it would not fit in the space the input took
    /// with a little to spare — which also means it was not worth it.
    fileprivate static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    // MARK: - CRC-32

    /// zlib's, many bytes at a time; it counts at most 4 GB a call.
    package static func crc32(_ data: Data) -> UInt32 {
        var crc = zlib.crc32(0, nil, 0)
        data.withUnsafeBytes { raw in
            guard var next = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let chunk = min(left, Int(UInt32.max))
                crc = zlib.crc32(crc, next, uInt(chunk))
                next += chunk
                left -= chunk
            }
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    // MARK: - Byte access

    private static func readUInt16(_ bytes: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64(_ bytes: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        return UInt64(readUInt32(bytes, offset)) | (UInt64(readUInt32(bytes, offset + 4)) << 32)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(value & 0xFFFF_FFFF))
        appendUInt32(UInt32(value >> 32))
    }
}
