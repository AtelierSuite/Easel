import CoreGraphics
import Foundation
import Testing
@testable import Easel

@Suite("Photoshop preset warps")
struct PSDWarpPresetTests {
    private let bounds = CGRect(x: 10, y: 5, width: 60, height: 20)

    private func mesh(_ style: String, _ bend: Double, vertical: Bool = false) throws -> [CGPoint] {
        try #require(PSDWarpPresets.mesh(
            style: style, bend: bend, vertical: vertical, horizontalDistortion: 0, verticalDistortion: 0, bounds: bounds
        ))
    }

    @Test(arguments: Array(PSDWarpPresets.styles))
    func noBendLeavesTheContents(_ style: String) throws {
        let points = try mesh(style, 0)
        #expect(points.count == 16)
        for (index, point) in points.enumerated() {
            #expect(abs(point.x - (bounds.minX + bounds.width * Double(index % 4) / 3)) < 1e-9)
            #expect(abs(point.y - (bounds.minY + bounds.height * Double(index / 4) / 3)) < 1e-9)
        }
    }

    @Test func aFlagWavesByTwiceTheHeight() throws {
        let points = try mesh("warpFlag", 50)
        // A bend of 50 moves the inner handles by the height either way.
        #expect(abs(points[1].y - (bounds.minY - 20)) < 1e-9)
        #expect(abs(points[2].y - (bounds.minY + 20)) < 1e-9)
    }

    @Test func anArcKeepsItsBottomCorners() throws {
        let points = try mesh("warpArc", 50)
        #expect(abs(points[12].x - bounds.minX) < 1e-9 && abs(points[12].y - bounds.maxY) < 1e-9)
        #expect(abs(points[15].x - bounds.maxX) < 1e-9 && abs(points[15].y - bounds.maxY) < 1e-9)
        // The top corners swing out and down about them.
        #expect(points[0].x < bounds.minX && points[0].y > bounds.minY)
    }

    @Test func distortionWidensOneSide() throws {
        let points = try #require(PSDWarpPresets.mesh(
            style: "warpFlag", bend: 0, vertical: false, horizontalDistortion: 50, verticalDistortion: 0, bounds: bounds
        ))
        let leftHeight = points[12].y - points[0].y, rightHeight = points[15].y - points[3].y
        #expect(rightHeight > leftHeight * 2)
    }

    @Test func aPresetBendIsReadAsAGrid() throws {
        func rect(_ items: (String, Double)...) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: "Rctn", items: items.map { ($0.0, .unit("#Pxl", $0.1)) }))
        }
        let corners: [PSDDescriptor.Value] = [0, 0, 60, 0, 60, 20, 0, 20].map { .double($0) }
        let descriptor = PSDDescriptor(classID: "null", items: [
            ("Idnt", .text("contents")), ("Trnf", .list(corners)), ("nonAffineTransform", .list(corners)),
            ("warp", .descriptor(PSDDescriptor(classID: "warp", items: [
                ("warpStyle", .enumerated(type: "warpStyle", value: "warpArch")), ("warpValue", .double(40)),
                ("warpPerspective", .double(0)), ("warpPerspectiveOther", .double(0)),
                ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
                ("bounds", rect(("Top ", 0), ("Left", 0), ("Btom", 20), ("Rght", 60))),
            ]))),
        ])
        var block = PSDBinaryWriter()
        block.ascii("soLD")
        block.uint32(4)
        block.bytes(descriptor.versionedBytes)
        let placement = try #require(PSDSmartObjects.placement(from: block.data))
        let grid = try #require(placement.mesh)
        #expect(grid.count == 16)
        // Arched up: the top edge's middle handles rise above the corners.
        #expect(grid[1].y < grid[0].y)
    }

    @Test func aCylinderStaysAsPixels() throws {
        let corners: [PSDDescriptor.Value] = [0, 0, 60, 0, 60, 20, 0, 20].map { .double($0) }
        let descriptor = PSDDescriptor(classID: "null", items: [
            ("Idnt", .text("contents")), ("nonAffineTransform", .list(corners)),
            ("warp", .descriptor(PSDDescriptor(classID: "warp", items: [
                ("warpStyle", .enumerated(type: "warpStyle", value: "warpCylinder")),
                ("warpValues", .list([0, 20, 60, 0, 0.5, 0.5, 0.5].map { .double($0) })),
            ]))),
        ])
        var block = PSDBinaryWriter()
        block.ascii("soLD")
        block.uint32(4)
        block.bytes(descriptor.versionedBytes)
        #expect(PSDSmartObjects.placement(from: block.data) == nil)
    }
}
