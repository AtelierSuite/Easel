import CoreGraphics
import Foundation

/// One region of overlapping shapes, as the Shape Builder offers them:
/// every area bounded by the shapes' edges is a region of its own.
package struct ShapeBuilderFace: @unchecked Sendable {
    package var path: CGPath
    /// The shape whose look the region takes: the topmost one over it.
    package var style: VectorPath
}

package enum ShapeBuilder {
    /// The regions the closed shapes among `paths` cut each other into.
    package static func faces(of paths: [VectorPath]) -> [ShapeBuilderFace] {
        let closed = paths.filter { $0.isClosed && $0.nodes.count > 2 }
        var regions: [(path: CGPath, top: Int)] = []
        var covered: CGPath = CGMutablePath()
        for (index, shape) in closed.enumerated() {
            let outline = shape.cgPath.normalized(using: .evenOdd)
            var next: [(path: CGPath, top: Int)] = []
            for region in regions {
                for piece in [region.path.intersection(outline, using: .evenOdd)] where !isEmpty(piece) {
                    next.append((piece, index))
                }
                let rest = region.path.subtracting(outline, using: .evenOdd)
                if !isEmpty(rest) { next.append((rest, region.top)) }
            }
            let fresh = outline.subtracting(covered, using: .evenOdd)
            if !isEmpty(fresh) { next.append((fresh, index)) }
            covered = covered.union(outline, using: .evenOdd)
            regions = next
        }
        // Pieces apart from each other are regions apart.
        return regions.flatMap { region in
            region.path.componentsSeparated(using: .evenOdd).filter { !isEmpty($0) }.map {
                ShapeBuilderFace(path: $0, style: closed[region.top])
            }
        }
    }

    /// The picked regions joined into one shape, styled as the topmost of
    /// them, with the rest left as shapes of their own.
    package static func merging(_ picked: Set<Int>, of faces: [ShapeBuilderFace]) -> [VectorPath] {
        var result = faces.indices.filter { !picked.contains($0) }.compactMap { shape(faces[$0].path, styledAs: faces[$0].style) }
        let chosen = picked.sorted().filter { faces.indices.contains($0) }
        guard let first = chosen.first else { return result }
        let joined = chosen.dropFirst().reduce(faces[first].path) { $0.union(faces[$1].path, using: .evenOdd) }
        // On top, as one shape.
        let style = chosen.map { faces[$0].style }.last ?? faces[first].style
        if let merged = shape(joined, styledAs: style) { result.append(merged) }
        return result
    }

    /// Every region but the picked ones, each a shape of its own.
    package static func deleting(_ picked: Set<Int>, of faces: [ShapeBuilderFace]) -> [VectorPath] {
        faces.indices.filter { !picked.contains($0) }.compactMap { shape(faces[$0].path, styledAs: faces[$0].style) }
    }

    private static func shape(_ path: CGPath, styledAs style: VectorPath) -> VectorPath? {
        let contours = VectorBoolean.contours(of: path)
        guard let first = contours.first else { return nil }
        var shape = style
        shape.id = UUID()
        shape.nodes = first
        shape.extraContours = contours.count > 1 ? Array(contours.dropFirst()) : nil
        shape.isClosed = true
        shape.liveShape = nil
        shape.text = nil
        if shape.fill == nil { shape.fill = shape.stroke }
        return shape
    }

    private static func isEmpty(_ path: CGPath) -> Bool {
        let box = path.boundingBoxOfPath
        return box.isNull || box.width < 0.01 || box.height < 0.01
    }
}
