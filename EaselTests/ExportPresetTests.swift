import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Export presets")
struct ExportPresetTests {
    @Test func picturesShrinkToFitAndAreNeverEnlarged() {
        let web = ExportPreset(name: "Web", format: .jpeg, maxWidth: 1600, maxHeight: 1600)
        #expect(web.outputSize(for: CGSize(width: 4000, height: 3000)) == CGSize(width: 1600, height: 1200))
        #expect(web.outputSize(for: CGSize(width: 800, height: 600)) == CGSize(width: 800, height: 600))
        let narrow = ExportPreset(name: "Narrow", format: .png, maxWidth: 100)
        #expect(narrow.outputSize(for: CGSize(width: 400, height: 1000)) == CGSize(width: 100, height: 250))
    }

    @Test func aPresetWritesItsFormatAtItsSize() throws {
        var composition = Composition.blank(size: CGSize(width: 400, height: 200))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 400, height: 200))
        let thumbnail = ExportPreset(name: "Thumb", format: .jpeg, maxWidth: 100, maxHeight: 100)
        let image = try ImageCodec.decode(try thumbnail.data(for: composition))
        #expect((image.width, image.height) == (100, 50))
        #expect(TestImages.isRed(image, x: 10, y: 25))
    }

    @Test func fileNamesCarryThePresetAndAreSafe() {
        let preset = ExportPreset(name: "App Store", format: .png)
        #expect(preset.filename(for: "My: Picture") == "My- Picture - App Store.png")
        #expect(preset.filename(for: "") == String(localized: "Export.DefaultName") + " - App Store.png")
    }

    @Test func aBatchMakesOneFilePerPreset() async throws {
        let composition = Composition.blank(size: CGSize(width: 40, height: 20))
        let presets = [
            ExportPreset(name: "Web", format: .jpeg), ExportPreset(name: "Web", format: .jpeg),
            ExportPreset(name: "Lossless", format: .png),
        ]
        let files = try await ExportPreset.export(composition, named: "Sketch", with: presets)
        defer { try? FileManager.default.removeItem(at: files[0].deletingLastPathComponent()) }
        #expect(files.count == 3)
        #expect(Set(files).count == 3)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(files.map(\.pathExtension) == ["jpg", "jpg", "png"])
    }

    @Test func theSummaryNamesFormatSizeAndQuality() {
        let preset = ExportPreset(name: "Web", format: .jpeg, quality: 0.8, maxWidth: 1600, maxHeight: 1600)
        #expect(preset.summary == "JPEG · 1600 × 1600 px · 80%")
        #expect(!ExportPreset(name: "PNG", format: .png).summary.contains("%"))
    }
}

@MainActor
@Suite("Export preset library")
struct ExportPresetLibraryTests {
    @Test func savedPresetsAreKeptBetweenLaunches() throws {
        let suite = "ExportPresetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = ExportPresetLibrary(defaults: defaults)
        library.save(ExportPreset(name: " Banner ", format: .png, maxWidth: 1500))
        library.save(ExportPreset(name: "  ", format: .png))
        let reopened = ExportPresetLibrary(defaults: defaults)
        #expect(reopened.saved.map(\.name) == ["Banner"])
        #expect(reopened.all.count == ExportPreset.builtIn.count + 1)
        reopened.delete(try #require(reopened.saved.first))
        #expect(ExportPresetLibrary(defaults: defaults).saved.isEmpty)
    }
}
