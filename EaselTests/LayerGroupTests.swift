import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Layer groups")
struct LayerGroupTests {
    private let size = CGSize(width: 8, height: 8)

    private func layer(_ name: String, _ color: RGBAColor, group: UUID? = nil) -> Layer {
        var layer = Layer(name: name, image: LayerImage(TestImages.solid(color, width: 8, height: 8)), canvasSize: size)
        layer.groupID = group
        return layer
    }

    @Test func hiddenGroupsHideTheirLayers() {
        let group = LayerGroup(name: "G", isVisible: false)
        let composition = Composition(size: size, layers: [
            layer("Red", RGBAColor(red: 1, green: 0, blue: 0)),
            layer("Blue", RGBAColor(red: 0, green: 0, blue: 1), group: group.id),
        ], groups: [group])
        #expect(TestImages.isRed(CompositionRenderer.render(composition), x: 4, y: 4))
    }

    @Test func nestedGroupsMultiplyOpacity() {
        let outer = LayerGroup(name: "Outer", opacity: 0.5)
        let inner = LayerGroup(name: "Inner", parentID: outer.id, opacity: 0.5)
        let composition = Composition(size: size, layers: [layer("Ink", .black, group: inner.id)], groups: [outer, inner])
        #expect(abs(composition.displayLayers[0].opacity - 0.25) < 0.0001)
    }

    @Test func normalizingKeepsGroupsTogetherAndDropsEmptyOnes() {
        let group = LayerGroup(name: "G")
        let empty = LayerGroup(name: "Empty")
        var composition = Composition(size: size, layers: [
            layer("A", .black, group: group.id), layer("B", .white), layer("C", .black, group: group.id),
        ], groups: [group, empty])
        composition.normalizeGroups()
        #expect(composition.layers.map(\.name) == ["A", "C", "B"])
        #expect(composition.groups.map(\.name) == ["G"])
    }

    @Test func rowsListHeadersAboveTheirLayers() {
        var group = LayerGroup(name: "G")
        let composition = Composition(size: size, layers: [
            layer("Bottom", .black), layer("In", .black, group: group.id), layer("Top", .black),
        ], groups: [group])
        let names = composition.layerListRows.map { row -> String in
            switch row {
            case .group(let group, let depth): return "[\(group.name)]\(depth)"
            case .layer(let layer, let depth): return "\(layer.name)\(depth)"
            }
        }
        #expect(names == ["Top0", "[G]0", "In1", "Bottom0"])
        group.isExpanded = false
        let collapsed = Composition(size: size, layers: composition.layers, groups: [group])
        #expect(collapsed.layerListRows.count == 3)
    }

    @Test func draggingUnderAHeaderJoinsTheGroup() {
        let group = LayerGroup(name: "G")
        var composition = Composition(size: size, layers: [
            layer("Bottom", .black), layer("In", .black, group: group.id), layer("Top", .black),
        ], groups: [group])
        // Rows: Top, [G], In, Bottom. Drag Top to just under the header.
        composition.moveLayer(fromRow: 0, toRow: 2)
        #expect(composition.layers.first { $0.name == "Top" }?.groupID == group.id)
        #expect(composition.layers.map(\.name) == ["Bottom", "In", "Top"])
        // Drag it back out above the group.
        let rows = composition.layerListRows
        let from = rows.firstIndex { $0.id == composition.layers[2].id }!
        composition.moveLayer(fromRow: from, toRow: 0)
        #expect(composition.layers.last?.groupID == nil)
    }

    @Test func groupsAreSaved() throws {
        let group = LayerGroup(name: "Saved", opacity: 0.4, isLocked: true)
        let composition = Composition(size: size, layers: [layer("In", .black, group: group.id)], groups: [group])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).easel")
        try CompositionArchive.fileWrapper(for: composition).write(to: url, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CompositionArchive.composition(from: FileWrapper(url: url))
        #expect(read.groups == [group])
        #expect(read.layers[0].groupID == group.id)
    }

    /// Passing through, a group's layers mix with what is beneath it; in
    /// any other mode, only with each other.
    @Test func groupsInABlendModeMixAsOne() {
        let red = RGBAColor(red: 1, green: 0, blue: 0), green = RGBAColor(red: 0, green: 1, blue: 0)
        for mode in [nil, LayerBlendMode.normal] {
            let group = LayerGroup(name: "G", blendMode: mode)
            var screened = layer("Green", green, group: group.id)
            screened.blendMode = .screen
            let composition = Composition(size: size, layers: [layer("Red", red), screened], groups: [group])
            let pixel = TestImages.pixel(CompositionRenderer.render(composition), x: 4, y: 4)
            let alone = TestImages.pixel(screened.image.cgImage, x: 4, y: 4)
            // Screened with red, yellow; on its own, green.
            #expect(mode == nil ? pixel.red > alone.red + 60 : abs(pixel.red - alone.red) < 3)
        }
    }

    @Test func aGroupsOpacityFadesItAsOne() {
        let group = LayerGroup(name: "G", opacity: 0.5, blendMode: .normal)
        let composition = Composition(size: size, layers: [
            layer("White", .white),
            layer("Red", RGBAColor(red: 1, green: 0, blue: 0), group: group.id),
            layer("Black", .black, group: group.id),
        ], groups: [group])
        // Half black over white: the red under the black never shows.
        let pixel = TestImages.pixel(CompositionRenderer.render(composition), x: 4, y: 4)
        #expect(abs(pixel.red - pixel.green) < 4)
        #expect(pixel.red > 100 && pixel.red < 160)
    }

    @Test func groupBlendModesAreSavedAndOldFilesPassThrough() throws {
        let group = LayerGroup(name: "Saved", blendMode: .multiply)
        let data = try JSONEncoder().encode(group)
        #expect(try JSONDecoder().decode(LayerGroup.self, from: data) == group)
        var older = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["blendMode"] = nil
        let read = try JSONDecoder().decode(LayerGroup.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(read.blendMode == nil)
    }

    @Test func groupBlendModesSurviveAPhotoshopRoundTrip() throws {
        let multiplied = LayerGroup(name: "Multiplied", blendMode: .multiply)
        let passing = LayerGroup(name: "Passing")
        let composition = Composition(size: size, layers: [
            layer("A", .black, group: multiplied.id), layer("B", .white, group: passing.id),
        ], groups: [multiplied, passing])
        let read = try PSDReader.composition(from: try PSDWriter.data(for: composition))
        #expect(read.groups.map(\.name) == ["Multiplied", "Passing"])
        #expect(read.groups.map(\.blendMode) == [.multiply, nil])
    }
}

@MainActor
@Suite("Group commands")
struct GroupCommandTests {
    private func editor() -> EditorState {
        let state = EditorState()
        state.attach(to: .blank(size: CGSize(width: 10, height: 10))) { _ in }
        return state
    }

    @Test func groupingAndUngrouping() throws {
        let state = editor()
        state.groupActiveLayer()
        let groupID = try #require(state.activeGroupID)
        #expect(state.composition.layers[0].groupID == groupID)
        state.ungroup(groupID)
        #expect(state.composition.groups.isEmpty)
        #expect(state.composition.layers[0].groupID == nil)
    }

    @Test func lockedGroupsLockTheirLayers() throws {
        let state = editor()
        let layerID = try #require(state.activeLayerID)
        state.groupActiveLayer()
        state.updateGroup(state.activeGroupID!) { $0.isLocked = true }
        state.activeLayerID = layerID
        #expect(state.paintingBlocker() != nil)
    }

    @Test func movingAGroupMovesItsLayers() throws {
        let state = editor()
        state.addEmptyLayer()
        let top = try #require(state.activeLayerID)
        state.groupActiveLayer()
        let groupID = try #require(state.activeGroupID)
        state.moveLayer(state.composition.layers[0].id, toGroup: groupID)
        state.activeGroupID = groupID
        state.tool = .move
        state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 4, y: 3))])
        state.toolEnded(isTap: false, at: CGPoint(x: 4, y: 3))
        #expect(state.composition.layers.allSatisfy { $0.transform.position == CGPoint(x: 8, y: 7) })
        _ = top
    }

    @Test func mergingAGroupLeavesOneLayer() throws {
        let state = editor()
        state.addEmptyLayer()
        state.groupActiveLayer()
        let groupID = try #require(state.activeGroupID)
        state.moveLayer(state.composition.layers[0].id, toGroup: groupID)
        state.mergeGroup(groupID)
        #expect(state.composition.layers.count == 1)
        #expect(state.composition.groups.isEmpty)
    }
}
