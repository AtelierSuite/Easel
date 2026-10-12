import CoreGraphics
import Foundation
import SwiftUI

/// How a newly drawn selection meets the one already there.
enum SelectionMode: String, CaseIterable, Identifiable, Sendable {
    case replace, add, subtract, intersect

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .replace: return "square.dashed"
        case .add: return "plus.square.dashed"
        case .subtract: return "minus.square"
        case .intersect: return "square.on.square.intersection.dashed"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .replace: return "Select.Mode.Replace"
        case .add: return "Select.Mode.Add"
        case .subtract: return "Select.Mode.Subtract"
        case .intersect: return "Select.Mode.Intersect"
        }
    }
}

extension Selection {
    /// The selection as pixels on a canvas of `size`, however it was made.
    func mask(canvasSize size: CGSize) -> SelectionMask? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        return SelectionMask(bytes: coverage(width: width, height: height), width: width, height: height)
    }

    /// This selection combined with `other`, drawn after it. Nil when
    /// nothing is left selected.
    func combined(with other: Selection, mode: SelectionMode, canvasSize size: CGSize) -> Selection? {
        guard mode != .replace else { return other }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let mine = coverage(width: width, height: height)
        let theirs = other.coverage(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for index in bytes.indices {
            let a = mine[index], b = theirs[index]
            switch mode {
            case .replace: bytes[index] = b
            case .add: bytes[index] = max(a, b)
            case .subtract: bytes[index] = min(a, 255 - b)
            case .intersect: bytes[index] = min(a, b)
            }
        }
        return SelectionMask(bytes: bytes, width: width, height: height).map { Selection(shape: .mask($0)) }
    }
}
