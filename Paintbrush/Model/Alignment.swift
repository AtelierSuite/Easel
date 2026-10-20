import CoreGraphics
import Foundation
import SwiftUI

/// The edge or middle layers are lined up along.
package enum AlignEdge: String, CaseIterable, Identifiable, Sendable {
    case left, centerX, right, top, centerY, bottom

    package var id: String { rawValue }

    package var label: LocalizedStringKey {
        switch self {
        case .left: return "Align.Left"
        case .centerX: return "Align.CenterX"
        case .right: return "Align.Right"
        case .top: return "Align.Top"
        case .centerY: return "Align.CenterY"
        case .bottom: return "Align.Bottom"
        }
    }

    package var symbolName: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .centerX: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .centerY: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        }
    }

    /// Where `rect` has this edge, along its axis.
    package func value(of rect: CGRect) -> Double {
        switch self {
        case .left: return rect.minX
        case .centerX: return rect.midX
        case .right: return rect.maxX
        case .top: return rect.minY
        case .centerY: return rect.midY
        case .bottom: return rect.maxY
        }
    }

    package var isHorizontal: Bool { [.left, .centerX, .right].contains(self) }
}

extension Composition {
    /// Moves each layer so its edge lines up with the same edge of `target`.
    package mutating func align(_ ids: [Layer.ID], _ edge: AlignEdge, to target: CGRect) {
        let goal = edge.value(of: target)
        for id in ids {
            guard let index = index(of: id) else { continue }
            let shift = goal - edge.value(of: layers[index].bounds)
            if edge.isHorizontal {
                layers[index].transform.position.x += shift
            } else {
                layers[index].transform.position.y += shift
            }
        }
    }

    /// Moves the layers between the outermost two so the gaps between them
    /// all come out the same, across or down.
    package mutating func distribute(_ ids: [Layer.ID], horizontally: Bool) {
        let members = ids.compactMap { id in index(of: id).map { (index: $0, bounds: layers[$0].bounds) } }
        guard members.count > 2 else { return }
        let sorted = members.sorted { horizontally ? $0.bounds.midX < $1.bounds.midX : $0.bounds.midY < $1.bounds.midY }
        let start = horizontally ? sorted.first!.bounds.minX : sorted.first!.bounds.minY
        let end = horizontally ? sorted.last!.bounds.maxX : sorted.last!.bounds.maxY
        let filled = sorted.reduce(0.0) { $0 + (horizontally ? $1.bounds.width : $1.bounds.height) }
        let gap = (end - start - filled) / Double(sorted.count - 1)
        var cursor = start
        for member in sorted {
            let current = horizontally ? member.bounds.minX : member.bounds.minY
            if horizontally {
                layers[member.index].transform.position.x += cursor - current
                cursor += member.bounds.width + gap
            } else {
                layers[member.index].transform.position.y += cursor - current
                cursor += member.bounds.height + gap
            }
        }
    }
}
