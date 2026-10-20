import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Writing Pixelmator Pro documents")
struct PXDWriterTests {
    private let red = PXDPixels.bgra(0, 0, 255, width: 4, height: 4)
    private let blue = PXDPixels.bgra(255, 0, 0, width: 4, height: 4)

    /// A text layer on top, a painted red layer, and a placed blue picture
    /// at the bottom, in a 4×4 document.
    private func document(zipped: Bool = true, extra: [PXDBuilder.LayerSpec] = []) throws -> FileWrapper {
        let png = try ImageCodec.encode(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 4, height: 4), as: .png)
        return try PXDBuilder(canvas: (4, 4), layers: [
            .init(identifier: "TEXT", index: 0, type: 2, name: "Title", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 1)),
            .init(identifier: "RED", index: 1, type: 1, name: "Red", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 4), pixels: red),
            .init(identifier: "BLUE", index: 2, type: 1, name: "Blue", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 4), original: png),
        ] + extra, zipped: zipped).build()
    }

    private func layer(_ composition: Composition, _ name: String) throws -> Layer {
        try #require(composition.layers.first { $0.name == name })
    }

    private func entries(_ wrapper: FileWrapper) throws -> [String: ZipArchive.Entry] {
        let raw = try ZipArchive.rawEntries(in: try #require(wrapper.regularFileContents))
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.name, $0) })
    }

    /// The layer table, top first under each parent.
    private func rows(_ wrapper: FileWrapper) throws -> [(identifier: String, parent: String?, index: Int, type: Int)] {
        let metadata: Data
        if wrapper.isDirectory {
            metadata = try #require(wrapper.fileWrappers?["metadata.info"]?.regularFileContents)
        } else {
            metadata = try #require(try entries(wrapper)["metadata.info"]?.contents())
        }
        let database = try PXDFormat.Database(data: metadata)
        return database.layers()
            .sorted { ($0.parent ?? "", $0.index) < ($1.parent ?? "", $1.index) }
            .map { ($0.identifier, $0.parent, $0.index, $0.type) }
    }

    /// One row's settings.
    private func info(_ wrapper: FileWrapper, _ identifier: String) throws -> [String: [UInt8]] {
        let metadata = try #require(try entries(wrapper)["metadata.info"]?.contents())
        let database = try PXDFormat.Database(data: metadata)
        let row = try #require(database.layers().first { $0.identifier == identifier })
        return database.info(for: row.id)
    }

    @Test func unchangedDocumentsAreLeftAsTheyWere() throws {
        let original = try document()
        let composition = try PXDReader.composition(from: original)
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(written.regularFileContents == original.regularFileContents)
    }

    /// Painting one layer rewrites only that layer's pixels, the database
    /// and the previews; every other file is copied byte for byte.
    @Test func paintingOneLayerRewritesOnlyIt() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        let index = try #require(composition.layers.firstIndex { $0.name == "Red" })
        composition.layers[index].image = LayerImage(TestImages.solid(RGBAColor(red: 0, green: 1, blue: 0), width: 4, height: 4))
        let written = try PXDWriter.fileWrapper(for: composition, original: original)

        let before = try entries(original)
        let after = try entries(written)
        #expect(Set(before.keys) == Set(after.keys))
        for (name, entry) in before where !["metadata.info", "data/RED", "QuickLook/Thumbnail.png"].contains(name) {
            #expect(after[name] == entry, "\(name)")
        }
        #expect(after["data/RED"] != before["data/RED"])
        // Still a painted buffer, in the same format.
        let redEntry = try #require(after["data/RED"])
        let buffer = try #require(PXDFormat.BitmapBuffer(try redEntry.contents()))
        #expect(buffer.channels == 4)
        #expect(buffer.compression == PXDFormat.BitmapBuffer.deflate)

        let reread = try PXDReader.composition(from: written)
        #expect(reread.layers.map(\.name) == composition.layers.map(\.name))
        let green = try layer(reread, "Red")
        let pixels = try #require(Bitmap.pixels(of: green.image.cgImage)).color(x: 2, y: 2)
        // sRGB green, as Display P3 shows it.
        #expect(pixels.green > 240 && pixels.red < 130 && pixels.blue < 100, "\(pixels)")
        #expect(TestImages.isRed(try layer(reread, "Blue").image.cgImage, x: 1, y: 1) == false)
    }

    @Test func settingsAreWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        let index = try #require(composition.layers.firstIndex { $0.name == "Blue" })
        composition.layers[index].name = "Sky"
        composition.layers[index].opacity = 0.25
        composition.layers[index].isVisible = false
        composition.layers[index].blendMode = .screen
        composition.layers[index].transform = LayerTransform(position: CGPoint(x: 1, y: 3), scaleX: 0.5, scaleY: 0.5, rotation: -.pi / 2)
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        // Placed pictures that were only moved keep their file.
        #expect(try entries(written)["data/BLUE-OriginalContentSource"] == entries(original)["data/BLUE-OriginalContentSource"])

        let sky = try layer(try PXDReader.composition(from: written), "Sky")
        #expect(abs(sky.opacity - 0.25) < 0.001)
        #expect(!sky.isVisible)
        #expect(sky.blendMode == .screen)
        #expect(abs(sky.transform.position.x - 1) < 0.001 && abs(sky.transform.position.y - 3) < 0.001)
        #expect(abs(sky.transform.scaleX - 0.5) < 0.001)
        #expect(abs(sky.transform.rotation + .pi / 2) < 0.001)
    }

    /// Pixelmator keeps a lock and a clipping mask as bits of the flags,
    /// which come in and go back with the rest.
    @Test func locksAndClippingAreWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        #expect(composition.layers.allSatisfy { !$0.isLocked && !$0.isClipped })
        let red = try #require(composition.layers.firstIndex { $0.name == "Red" })
        composition.layers[red].isClipped = true
        let blue = try #require(composition.layers.firstIndex { $0.name == "Blue" })
        composition.layers[blue].isLocked = true
        var group = LayerGroup(name: "Folder")
        group.isLocked = true
        composition.groups.append(group)
        composition.layers[blue].groupID = group.id
        composition.normalizeGroups()
        let written = try PXDWriter.fileWrapper(for: composition, original: original)

        let reread = try PXDReader.composition(from: written)
        #expect(try layer(reread, "Red").isClipped)
        #expect(try !layer(reread, "Red").isLocked)
        #expect(try layer(reread, "Blue").isLocked)
        #expect(try !layer(reread, "Blue").isClipped)
        #expect(reread.groups.first?.isLocked == true)

        // And off again.
        var unlocked = reread
        for index in unlocked.layers.indices {
            unlocked.layers[index].isLocked = false
            unlocked.layers[index].isClipped = false
        }
        let again = try PXDReader.composition(from: try PXDWriter.fileWrapper(for: unlocked, original: written))
        #expect(again.layers.allSatisfy { !$0.isLocked && !$0.isClipped })
    }

    /// An adjustment layer goes in as a colour adjustments layer with
    /// Pixelmator's like control set, and comes back as it was.
    @Test func adjustmentLayersAreWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        var adjustment = composition.adjustmentLayer(.saturation)
        adjustment.adjustment?.amount = -0.4
        adjustment.isClipped = true
        composition.layers.append(adjustment)
        let once = try PXDWriter.fileWrapper(for: composition, original: original)
        let table = try rows(once)
        #expect(table.first { $0.identifier == adjustment.id.uuidString }?.type == PXDFormat.adjustmentsLayer)
        let json = try #require(try info(once, adjustment.id.uuidString)[PXDAdjustments.key])
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(json)) as? [Any])
        let hueSaturation = try #require(((settings[1] as? [String: Any])?["hS"] as? [Any])?[1] as? [String: Any])
        #expect((hueSaturation["s"] as? Double) == -0.4)
        #expect((hueSaturation["E"] as? Int) == 1)

        let reread = try PXDReader.composition(from: once)
        let back = try #require(reread.layers.first { $0.isAdjustment })
        #expect(back.adjustment == adjustment.adjustment)
        #expect(back.isClipped)
        #expect(back.pixelmator?.identifier == adjustment.id.uuidString)
        // Saving again changes nothing, and adds no second row or mask.
        let twice = try PXDWriter.fileWrapper(for: reread, original: once)
        #expect(twice.regularFileContents == once.regularFileContents)

        // A changed setting goes back in its row; a removed layer leaves.
        var changed = reread
        let index = try #require(changed.layers.firstIndex { $0.isAdjustment })
        changed.layers[index].adjustment?.amount = 0.3
        let edited = try PXDReader.composition(from: try PXDWriter.fileWrapper(for: changed, original: once))
        #expect(edited.layers.first { $0.isAdjustment }?.adjustment?.amount == 0.3)
        changed.layers.remove(at: index)
        #expect(try rows(try PXDWriter.fileWrapper(for: changed, original: once)).allSatisfy { $0.type != PXDFormat.adjustmentsLayer })
    }

    /// Filters Pixelmator has no control like stay out of the document.
    @Test func adjustmentsPixelmatorHasNothingLikeAreLeftOut() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        composition.layers.append(composition.adjustmentLayer(.gradientMap))
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(try rows(written).allSatisfy { $0.type != PXDFormat.adjustmentsLayer })
    }

    /// Colour adjustments layers Pixelmator made come in when they amount
    /// to one filter of Easel's, and the rest stay unread.
    @Test func pixelmatorAdjustmentLayersComeIn() throws {
        var index = 2
        func adjustments(_ json: String) -> PXDBuilder.LayerSpec {
            index += 1
            return .init(identifier: UUID().uuidString, index: index, type: PXDFormat.adjustmentsLayer, name: "Adjust", position: .zero,
                  size: .zero, info: [PXDAdjustments.key: Array(json.utf8)])
        }
        let exposure = adjustments(#"[3,{"l":[1,{"E":1,"V":1,"e":1.5,"b":0,"c":0,"h":0,"s":0,"B":0,"A":0,"C":0,"T":0}],"i":[1,{"E":0,"V":1,"i":1}],"av":1}]"#)
        let two = adjustments(#"[3,{"l":[1,{"E":1,"V":1,"e":1.5,"b":0.2}],"av":1}]"#)
        let warmth = adjustments(#"[3,{"w":[1,{"E":1,"V":1,"t":0.3,"T":0}],"av":1}]"#)
        let original = try document(extra: [exposure, two, warmth])
        let composition = try PXDReader.composition(from: original)
        let read = composition.layers.filter(\.isAdjustment)
        #expect(read.count == 1)
        #expect(read.first?.adjustment?.kind == .exposure)
        #expect(read.first?.adjustment?.value(0) == 1.5)
        #expect(read.first?.pixelmator?.identifier == exposure.identifier)
        // Read as it was, it goes back as it was.
        #expect(try PXDWriter.fileWrapper(for: composition, original: original).regularFileContents == original.regularFileContents)
    }

    @Test func eachControlComesBackAsItsFilter() throws {
        var filters: [LayerFilter] = []
        for kind in [LayerFilter.Kind.invert, .blackAndWhite, .sepia, .saturation, .brightness, .contrast] {
            var filter = LayerFilter(kind: kind)
            if kind != .invert { filter.amount = 0.35 }
            filters.append(filter)
        }
        var exposure = LayerFilter(kind: .exposure)
        exposure.setValue(-1.25, at: 0)
        var vibrance = LayerFilter(kind: .vibrance)
        vibrance.setValue(40, at: 0)
        filters += [exposure, vibrance]
        for filter in filters {
            let json = try #require(PXDAdjustments.json(for: filter))
            // From Pixelmator's settings alone, then with Easel's kept.
            let read = try #require(PXDAdjustments.filter(json: json), "\(filter.kind)")
            #expect(read.kind == filter.kind)
            #expect(read.amount == filter.amount || filter.kind == .exposure || filter.kind == .vibrance)
            #expect(read.value(0) == filter.value(0))
            #expect(PXDAdjustments.filter(json: json, kept: PXDAdjustments.kept(filter, json: json)) == filter)
        }
    }

    /// The text layer's place, scale and angle, in Pixelmator's points.
    private func textPlacement(_ wrapper: FileWrapper) throws -> (position: CGPoint, scale: CGPoint, angle: Double) {
        let values = PXDFormat.Info(values: try info(wrapper, "TEXT"))
        return (try #require(values.position), values.scale, values.angle)
    }

    /// Text Easel did not read moves as the canvas moved the layers, once:
    /// saving again does not move it twice.
    @Test func unreadLayersFollowTheCanvas() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        // Grown to the right and down, the top left staying put: the text,
        // measured up from the bottom, rises by the two rows added.
        composition.resize(to: CGSize(width: 6, height: 6), mode: .anchor, anchor: .zero)
        let grown = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(try textPlacement(grown).position == CGPoint(x: 2, y: 4))
        #expect(try PXDWriter.fileWrapper(for: composition, original: grown).regularFileContents == grown.regularFileContents)
        // Read again, nothing has moved since.
        #expect(try PXDReader.composition(from: grown).canvasChange == composition.canvasChange)

        // Doubled and flipped across: text is moved and scaled, but as in
        // Pixelmator, not mirrored.
        composition.resizeImage(to: CGSize(width: 12, height: 12))
        composition.flip(horizontal: true)
        let flipped = try PXDWriter.fileWrapper(for: composition, original: grown)
        let placement = try textPlacement(flipped)
        #expect(placement.position == CGPoint(x: 8, y: 8))
        #expect(placement.scale == CGPoint(x: 2, y: 2))

        // A quarter turn clockwise: the text turns with it.
        composition.rotate(clockwise: true)
        let turned = try textPlacement(try PXDWriter.fileWrapper(for: composition, original: flipped))
        #expect(abs(turned.angle - 90) < 1e-9 || abs(turned.angle - 270) < 1e-9)
    }

    /// A text layer Easel did not read keeps its row, and stays just above
    /// the layer it was above when the others are reordered.
    @Test func unreadLayersStayWhereTheyWere() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        composition.layers.removeAll { $0.pixelmator?.isPreview == true }
        composition.layers.reverse()
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        let table = try rows(written)
        #expect(table.filter { $0.parent == nil }.map(\.identifier) == ["BLUE", "TEXT", "RED"])
    }

    @Test func deletedLayersLeaveTheDocument() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        composition.layers.removeAll { $0.name == "Red" }
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(try entries(written)["data/RED"] == nil)
        #expect(try rows(written).map(\.identifier) == ["TEXT", "BLUE"])
        #expect(try PXDReader.composition(from: written).layers.contains { $0.name == "Red" } == false)
    }

    /// A new layer goes in as a placed picture, and saving again finds it
    /// rather than adding it twice.
    @Test func newLayersAreAddedOnce() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        var added = composition.emptyLayer(named: "New")
        added.image = LayerImage(TestImages.solid(RGBAColor(red: 0, green: 1, blue: 0), width: 4, height: 4))
        composition.layers.append(added)
        let once = try PXDWriter.fileWrapper(for: composition, original: original)
        let twice = try PXDWriter.fileWrapper(for: composition, original: once)
        let table = try rows(twice)
        #expect(table.filter { $0.parent == nil }.map(\.identifier) == [added.id.uuidString, "TEXT", "RED", "BLUE"])
        #expect(try entries(twice)["data/\(added.id.uuidString)-OriginalContentSource"] != nil)
        let reread = try layer(try PXDReader.composition(from: twice), "New")
        #expect(reread.pixelmator?.identifier == added.id.uuidString)
        #expect(reread.transform.position == CGPoint(x: 2, y: 2))
    }

    @Test func groupsAreWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        var group = LayerGroup(name: "Folder", opacity: 0.5)
        group.isVisible = false
        group.blendMode = .multiply
        composition.groups.append(group)
        for index in composition.layers.indices where composition.layers[index].name != "Blue" {
            composition.layers[index].groupID = group.id
        }
        composition.normalizeGroups()
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        let table = try rows(written)
        #expect(table.filter { $0.parent == nil }.map(\.identifier) == [group.id.uuidString, "TEXT", "BLUE"])
        #expect(table.filter { $0.parent == group.id.uuidString }.map(\.identifier) == ["RED"])

        let reread = try PXDReader.composition(from: written)
        let folder = try #require(reread.groups.first)
        #expect(folder.name == "Folder")
        #expect(abs(folder.opacity - 0.5) < 0.001)
        #expect(!folder.isVisible)
        #expect(folder.blendMode == .multiply)
        #expect(try layer(reread, "Red").groupID == folder.id)
    }

    @Test func masksAreWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        let index = try #require(composition.layers.firstIndex { $0.name == "Red" })
        // Shows the left half.
        let mask = Bitmap.render(size: CGSize(width: 4, height: 4)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
        }
        composition.layers[index].mask = LayerMask(image: LayerImage(mask))
        let added = try PXDWriter.fileWrapper(for: composition, original: original)
        var reread = try PXDReader.composition(from: added)
        let masked = try layer(reread, "Red")
        let maskImage = try #require(masked.mask).image.cgImage
        let pixels = try #require(Bitmap.pixels(of: maskImage))
        #expect(pixels.color(x: 0, y: 1).alpha > 250)
        #expect(pixels.color(x: 3, y: 1).alpha < 5)

        // Turned off, then taken away.
        let maskedIndex = try #require(reread.layers.firstIndex { $0.name == "Red" })
        reread.layers[maskedIndex].mask?.isEnabled = false
        let disabled = try PXDWriter.fileWrapper(for: reread, original: added)
        #expect(try layer(try PXDReader.composition(from: disabled), "Red").mask?.isEnabled == false)
        reread.layers[maskedIndex].mask = nil
        let removed = try PXDWriter.fileWrapper(for: reread, original: disabled)
        #expect(try layer(try PXDReader.composition(from: removed), "Red").mask == nil)
        #expect(try rows(removed).count == 3)
    }

    /// Sixteen-bit LZ4 layers are saved the way they came.
    @Test func sixteenBitLayersStaySixteenBit() throws {
        let pixel: [UInt8] = [0xFF, 0xFF, 0, 0, 0, 0, 0xFF, 0xFF]
        let deep = PXDPixels(bytes: Array(Array(repeating: pixel, count: 16).joined()), width: 4, height: 4, bits: 16, compression: 4)
        let original = try PXDBuilder(canvas: (4, 4), layers: [
            .init(identifier: "DEEP", index: 0, type: 1, name: "Deep", position: CGPoint(x: 2, y: 2),
                  size: CGSize(width: 4, height: 4), pixels: deep),
        ], zipped: true).build()
        var composition = try PXDReader.composition(from: original)
        composition.layers[0].image = LayerImage(TestImages.solid(RGBAColor(red: 0, green: 0, blue: 1), width: 4, height: 4))
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        let deepEntry = try #require(try entries(written)["data/DEEP"])
        let buffer = try #require(PXDFormat.BitmapBuffer(try deepEntry.contents()))
        #expect(buffer.bits == 16)
        #expect(buffer.compression == PXDFormat.BitmapBuffer.lz4)
        let color = try #require(Bitmap.pixels(of: try PXDReader.composition(from: written).layers[0].image.cgImage))
            .color(x: 1, y: 1)
        #expect(color.blue > 240 && color.red < 5, "\(color)")
    }

    /// Package folders keep every file nothing changed.
    @Test func packagesAreWrittenBack() throws {
        let original = try document(zipped: false)
        var composition = try PXDReader.composition(from: original)
        let index = try #require(composition.layers.firstIndex { $0.name == "Red" })
        composition.layers[index].name = "Renamed"
        var added = composition.emptyLayer(named: "New")
        added.image = LayerImage(TestImages.solid(.white, width: 4, height: 4))
        composition.layers.append(added)
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(written.isDirectory)
        let data = try #require(written.fileWrappers?["data"]?.fileWrappers)
        #expect(data["RED"] === original.fileWrappers?["data"]?.fileWrappers?["RED"])
        #expect(data["\(added.id.uuidString)-OriginalContentSource"] != nil)
        let reread = try PXDReader.composition(from: written)
        #expect(reread.layers.contains { $0.name == "Renamed" })
        #expect(reread.layers.contains { $0.name == "New" })
    }

    @Test func canvasSizeIsWrittenBack() throws {
        let original = try document()
        var composition = try PXDReader.composition(from: original)
        composition.size = CGSize(width: 6, height: 5)
        let written = try PXDWriter.fileWrapper(for: composition, original: original)
        #expect(try PXDReader.composition(from: written).size == CGSize(width: 6, height: 5))
    }
}
