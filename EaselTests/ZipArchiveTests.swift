import Foundation
import Testing
@testable import Easel

@Suite("ZIP archives")
struct ZipArchiveTests {
    private let text = Data(String(repeating: "Easel paints in layers. ", count: 200).utf8)
    private let noise: Data = {
        var state: UInt32 = 12345
        return Data((0..<4096).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }()

    private func sample() -> [ZipArchive.Entry] {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            ZipArchive.Entry(name: "metadata.info", contents: text, date: date),
            ZipArchive.Entry(name: "data/", contents: Data(), date: date),
            ZipArchive.Entry(name: "data/layer", contents: text, deflate: true, date: date),
            ZipArchive.Entry(name: "data/noise", contents: noise, deflate: true, date: date),
            ZipArchive.Entry(name: "QuickLook/画像.png", contents: Data(), date: date),
        ]
    }

    @Test func writtenEntriesReadBack() throws {
        let entries = sample()
        #expect(entries[2].method == 8)
        // Deflating made it bigger, so it is stored.
        #expect(entries[3].method == 0)
        let files = try ZipArchive.entries(in: ZipArchive.archive(entries))
        #expect(files["metadata.info"] == text)
        #expect(files["data/layer"] == text)
        #expect(files["data/noise"] == noise)
        #expect(files["QuickLook/画像.png"] == Data())
        #expect(files["data/"] == nil)
    }

    /// Read raw and written again, an archive comes out byte for byte the
    /// same, folders and order included.
    @Test func rawEntriesCopyThroughUntouched() throws {
        let archive = ZipArchive.archive(sample())
        let raw = try ZipArchive.rawEntries(in: archive)
        #expect(raw.map(\.name) == sample().map(\.name))
        #expect(raw == sample())
        #expect(ZipArchive.archive(raw) == archive)
    }

    /// Replacing one entry leaves every other entry's stored bytes as they
    /// were.
    @Test func replacingOneEntryKeepsTheRest() throws {
        var raw = try ZipArchive.rawEntries(in: ZipArchive.archive(sample()))
        let index = try #require(raw.firstIndex { $0.name == "metadata.info" })
        raw[index] = ZipArchive.Entry(name: "metadata.info", contents: Data("changed".utf8))
        let rewritten = try ZipArchive.rawEntries(in: ZipArchive.archive(raw))
        #expect(rewritten.map(\.name) == sample().map(\.name))
        for (old, new) in zip(sample(), rewritten) where old.name != "metadata.info" {
            #expect(old == new)
        }
        #expect(try rewritten[index].contents() == Data("changed".utf8))
    }

    @Test func zip64ArchivesReadBackTheSame() throws {
        let archive = ZipArchive.archive(sample(), forceZip64: true)
        // ZIP64 asks readers for version 4.5; nothing else differs.
        let raw = try ZipArchive.rawEntries(in: archive).map { entry in
            #expect(entry.versionNeeded == 45)
            var entry = entry
            entry.versionNeeded = 20
            return entry
        }
        #expect(raw == sample())
        #expect(try ZipArchive.entries(in: archive)["data/layer"] == text)
        // Written again without being made to, it needs no ZIP64 at all.
        #expect(ZipArchive.archive(raw) == ZipArchive.archive(sample()))
    }

    @Test func dataDescriptorsAreNotKept() throws {
        var entry = ZipArchive.Entry(name: "a", contents: text, deflate: true)
        entry.flags |= 1 << 3
        let raw = try ZipArchive.rawEntries(in: ZipArchive.archive([entry]))
        #expect(raw[0].flags & (1 << 3) == 0)
        #expect(try raw[0].contents() == text)
    }
}
