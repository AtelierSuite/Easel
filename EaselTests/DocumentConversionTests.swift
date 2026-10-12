import Foundation
import Testing
@testable import Easel

@Suite("Keep Layers")
struct DocumentConversionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func picturesAreReplaced() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appending(path: "Photo.png")
        try ImageCodec.encode(TestImages.solid(.white, width: 4, height: 4), as: .png).write(to: picture)
        let easel = try await DocumentConversion.convert(fileAt: picture, composition: .blank())
        #expect(easel.lastPathComponent == "Photo.easel")
        #expect(FileManager.default.fileExists(atPath: easel.path))
        #expect(!FileManager.default.fileExists(atPath: picture.path))
    }

    /// Photoshop and Pixelmator Pro files are saved as an Easel copy
    /// before they are edited, rather than converted where they lie.
    @Test func photoshopAndPixelmatorFilesRequireACopy() {
        for name in ["Sketch.pxd", "Poster.psb", "Layers.PSD"] {
            let url = URL(filePath: "/tmp/\(name)")
            #expect(DocumentConversion.requiresCopy(url))
            #expect(!DocumentConversion.canConvert(url))
        }
        for name in ["Photo.png", "Photo.jpg", "Painting.easel"] {
            #expect(!DocumentConversion.requiresCopy(URL(filePath: "/tmp/\(name)")))
        }
    }
}
