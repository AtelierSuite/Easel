import CoreGraphics
import Foundation
import Testing
import zlib
@testable import Easel
@testable import Paintbrush

@Suite("Document previews")
struct DocumentPreviewTests {
    /// A ZIP of stored (uncompressed) entries.
    private func zip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        for (name, data) in entries {
            let offset = UInt32(out.count)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
            let nameData = Data(name.utf8)
            out += le(UInt32(0x04034B50)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
            out += le(crc) + le(UInt32(data.count)) + le(UInt32(data.count)) + le(UInt16(nameData.count)) + le(UInt16(0))
            out += nameData + data
            central += le(UInt32(0x02014B50)) + le(UInt16(20)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
            central += le(crc) + le(UInt32(data.count)) + le(UInt32(data.count)) + le(UInt16(nameData.count))
            central += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(offset) + nameData
        }
        let start = UInt32(out.count)
        out += central
        out += le(UInt32(0x06054B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(entries.count)) + le(UInt16(entries.count))
        out += le(UInt32(central.count)) + le(start) + le(UInt16(0))
        return out
    }

    @Test func easelPackagesShowTheirThumbnail() throws {
        let composition = Composition(size: CGSize(width: 40, height: 20), layers: [
            Layer(name: "Halves", image: LayerImage(TestImages.halves(width: 40, height: 20)), canvasSize: CGSize(width: 40, height: 20)),
        ])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try CompositionArchive.fileWrapper(for: composition).write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(DocumentPreview.image(at: url))
        #expect(image.width == 40 && image.height == 20)
        #expect(TestImages.isRed(image, x: 2, y: 10))
    }

    @Test func zippedPixelmatorFilesShowTheirThumbnail() throws {
        let png = try ImageCodec.encode(TestImages.halves(width: 16, height: 8), as: .png)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pxd")
        try zip([("metadata.info", Data([1, 2, 3])), ("QuickLook/Thumbnail.png", png)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(DocumentPreview.image(at: url))
        #expect(image.width == 16)
    }

    /// Only the preview is read: other entries, even damaged ones, are
    /// left alone.
    @Test func onlyTheNamedEntryIsRead() throws {
        let png = try ImageCodec.encode(TestImages.halves(width: 16, height: 8), as: .png)
        var archive = zip([("metadata.info", Data([1, 2, 3])), ("QuickLook/Thumbnail.png", png)])
        // The first entry's bytes no longer match its checksum.
        archive[30 + "metadata.info".utf8.count] ^= 0xFF
        #expect(throws: (any Error).self) { try ZipArchive.entries(in: archive) }
        #expect(try ZipArchive.entry(named: "QuickLook/Thumbnail.png", in: archive) == png)
        #expect(try ZipArchive.entry(named: "QuickLook/Icon.webp", in: archive) == nil)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pxd")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DocumentPreview.image(at: url)?.width == 16)
    }

    /// A ZIP64 size too large to add to an offset is damage, not a crash.
    @Test func hugeZip64SizesAreRefused() {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let name = Data("QuickLook/Thumbnail.png".utf8), body = Data([1, 2, 3])
        var archive = le(UInt32(0x04034B50)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
        archive += le(UInt32(0)) + le(UInt32(3)) + le(UInt32(3)) + le(UInt16(name.count)) + le(UInt16(0)) + name + body
        let start = UInt32(archive.count)
        var central = le(UInt32(0x02014B50)) + le(UInt16(45)) + le(UInt16(45)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
        central += le(UInt32(0)) + le(UInt32(0xFFFF_FFFF)) + le(UInt32(3)) + le(UInt16(name.count)) + le(UInt16(12))
        central += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(UInt32(0)) + name
        central += le(UInt16(1)) + le(UInt16(8)) + le(UInt64(Int64.max - 8))
        archive += central
        archive += le(UInt32(0x06054B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(1)) + le(UInt16(1))
        archive += le(UInt32(central.count)) + le(start) + le(UInt16(0))
        #expect(throws: (any Error).self) { try ZipArchive.entry(named: "QuickLook/Thumbnail.png", in: archive) }
        #expect(throws: (any Error).self) { try ZipArchive.entries(in: archive) }
    }

    @Test func checksumsAreZIPs() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test func missingPreviewsGiveNothing() {
        #expect(DocumentPreview.image(at: URL(fileURLWithPath: "/nonexistent.easel")) == nil)
    }

    @Test func thumbnailsKeepTheirShape() {
        #expect(DocumentPreview.fit(CGSize(width: 400, height: 200), in: CGSize(width: 100, height: 100)) == CGSize(width: 100, height: 50))
    }
}
