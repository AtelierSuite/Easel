import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

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
        // The package took the picture's place, and nothing else was left.
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: easel.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Photo.easel"])
    }

    /// Photoshop and Pixelmator Pro files are never converted where they
    /// lie; they are saved as an Easel copy before they are edited only when
    /// writing them back would lose something.
    @Test func layeredDocumentsRequireACopyOnlyWhenTheyWouldLoseSomething() {
        let composition = Composition.blank()
        var lossy = composition
        lossy.writeBackLosses = [.layers]
        for name in ["Poster.psb", "Layers.PSD", "Sketch.pxd"] {
            let url = URL(filePath: "/tmp/\(name)")
            #expect(!DocumentConversion.requiresCopy(url, composition: composition))
            #expect(DocumentConversion.requiresCopy(url, composition: lossy))
            #expect(!DocumentConversion.canConvert(url))
        }
        for name in ["Photo.png", "Photo.jpg", "Painting.easel"] {
            #expect(!DocumentConversion.requiresCopy(URL(filePath: "/tmp/\(name)"), composition: lossy))
        }
    }

    /// Asking for a copy says what writing back would lose, each in words.
    @Test func everyLossIsDescribed() {
        let labels = WriteBackLoss.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("WriteBackLoss.") })
    }
}
