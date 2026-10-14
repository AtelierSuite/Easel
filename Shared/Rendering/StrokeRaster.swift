import CoreGraphics
import Foundation
import Synchronization

/// A stamped stroke as the canvas shows it while it is drawn: the part of
/// it that can no longer change, drawn once into tiles that grow with it,
/// and the dabs at its end, which still can.
struct StrokeRaster {
    /// Canvas-aligned pieces, in canvas coordinates.
    var tiles: [(rect: CGRect, image: CGImage)] = []
    /// The dabs still to be drawn over the tiles.
    var tail: [BrushDab] = []
    /// For a watercolour, whose wash spreads, the wash where the end of the
    /// stroke reaches, to be drawn in place of the tiles there.
    var tailWash: (image: CGImage, rect: CGRect)?
}

/// Strokes being drawn, each worked out only as far as it has grown since
/// the last time, so a long stroke costs no more each moment than a short
/// one. The stroke painted in when it lifts is worked out whole, as before;
/// this is only what the canvas shows meanwhile, the same pixels.
final class StrokeRasterCache: Sendable {
    static let shared = StrokeRasterCache()

    /// A few: the stroke under the finger, its mirror images, and those
    /// lifted but not yet painted in.
    private static let capacity = 12
    private let entries = Mutex<[Entry]>([])

    func raster(for stroke: Stroke, canvasSize: CGSize) -> StrokeRaster {
        let widths = stroke.widths
        let stable = stroke.stablePoints(widths: widths)
        let entry = entries.withLock { entries -> Entry in
            if let index = entries.firstIndex(where: { $0.continues(stroke, widths: widths, canvasSize: canvasSize) }) {
                let entry = entries.remove(at: index)
                entries.append(entry)
                return entry
            }
            let entry = Entry(stroke: stroke, canvasSize: canvasSize)
            entries.append(entry)
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
            return entry
        }
        return entry.raster(for: stroke, widths: widths, stable: stable)
    }

    /// One stroke's tiles and how far along it they reach.
    private final class Entry: @unchecked Sendable {
        // Unchecked: only touched by the canvas as it draws, one frame at a
        // time.
        /// The stroke with no points: what it is, without where it goes.
        let kind: Stroke
        let first: StrokePoint
        let canvasSize: CGSize
        /// Whether the paint it picks up had come when it started.
        let pickupReady: Bool
        /// The points walked so far, and their widths.
        private(set) var points: [StrokePoint] = []
        private var widths: [Double] = []
        private var walk: DabWalk?
        /// The dabs drawn into the tiles.
        private var drawn = 0
        private let tiles = TiledRaster()
        /// For a watercolour: how much of each pixel the dabs cover, and the
        /// wash worked out from it.
        private let coverage = TiledRaster()

        init(stroke: Stroke, canvasSize: CGSize) {
            var kind = stroke
            kind.points = []
            self.kind = kind
            first = stroke.points.first ?? StrokePoint(location: .zero)
            self.canvasSize = canvasSize
            pickupReady = stroke.pickup?.isReady ?? true
        }

        /// Whether `stroke` is this one grown, the part walked unchanged.
        func continues(_ stroke: Stroke, widths: [Double], canvasSize: CGSize) -> Bool {
            guard canvasSize == self.canvasSize, stroke.points.first == first,
                  (stroke.pickup?.isReady ?? true) == pickupReady, stroke.points.count >= points.count,
                  stroke.points.count > 1 || points.isEmpty else { return false }
            var bare = stroke
            bare.points = []
            guard bare == kind else { return false }
            for index in points.indices where stroke.points[index] != points[index] || widths[index] != self.widths[index] {
                return false
            }
            return true
        }

        func raster(for stroke: Stroke, widths: [Double], stable: Int) -> StrokeRaster {
            let isWash = stroke.settings.tip == .watercolor && !stroke.isEraser
            // The start is settled once the stroke has set off somewhere.
            if walk == nil, stable > 0, let start = stroke.startDabs(widths: widths) {
                walk = start
            }
            if var walk, stable > walk.reached {
                stroke.walkDabs(&walk, through: stable, widths: widths)
                self.walk = walk
                points = Array(stroke.points[...stable])
                self.widths = Array(widths[...stable])
            }
            let settled = walk?.dabs ?? []
            if settled.count > drawn {
                let fresh = Array(settled[drawn...])
                drawn = settled.count
                if isWash {
                    let area = Self.area(of: fresh)
                    coverage.draw(fresh, of: stroke, color: .white, canvasSize: canvasSize)
                    rewash(around: area, stroke: stroke)
                } else {
                    tiles.draw(fresh, of: stroke, color: stroke.isEraser ? .black : stroke.settings.color, canvasSize: canvasSize)
                }
            }
            // The rest of the stroke, worked out again each time.
            var tail: [BrushDab] = []
            if var rest = walk?.continuing ?? stroke.startDabs(widths: widths) {
                stroke.walkDabs(&rest, through: stroke.points.count - 1, widths: widths)
                tail = rest.dabs
            }
            guard isWash else { return StrokeRaster(tiles: tiles.images, tail: tail) }
            var raster = StrokeRaster(tiles: tiles.images)
            if !tail.isEmpty {
                let reach = margin(of: stroke)
                let rect = Self.area(of: tail).insetBy(dx: -reach, dy: -reach).integral
                    .intersection(CGRect(origin: .zero, size: canvasSize))
                if !rect.isEmpty, let image = wash(rect, stroke: stroke, adding: tail) {
                    raster.tailWash = (image, rect)
                }
            }
            return raster
        }

        /// How far a change to a watercolour's dabs changes its wash: as far
        /// as the blur its pooling is found by reaches.
        private func margin(of stroke: Stroke) -> Double {
            Double(2 * stroke.washBlurRadius + 2)
        }

        /// Works the wash out again where new dabs fell.
        private func rewash(around area: CGRect, stroke: Stroke) {
            let reach = margin(of: stroke)
            let rect = area.insetBy(dx: -reach, dy: -reach).integral.intersection(CGRect(origin: .zero, size: canvasSize))
            guard !rect.isEmpty, let image = wash(rect, stroke: stroke, adding: []) else { return }
            tiles.replace(rect, with: image)
        }

        /// The wash over `rect`, from the dabs drawn so far and `extra`.
        private func wash(_ rect: CGRect, stroke: Stroke, adding extra: [BrushDab]) -> CGImage? {
            // The pooling at a pixel depends on the dabs a blur's reach
            // around it, so they are read from that much further out.
            let reach = margin(of: stroke)
            let source = rect.insetBy(dx: -reach, dy: -reach).integral.intersection(CGRect(origin: .zero, size: canvasSize))
            let shape = Bitmap.render(size: source.size) { context in
                context.translateBy(x: -source.minX, y: -source.minY)
                for tile in coverage.images where tile.rect.intersects(source) {
                    Bitmap.draw(tile.image, in: tile.rect, context: context)
                }
                stroke.stamp(extra, in: context, color: .white)
                stroke.applyGrain(in: context)
            }
            guard let washed = stroke.washImage(of: shape, at: source) else { return nil }
            return washed.cropping(to: rect.offsetBy(dx: -source.minX, dy: -source.minY))
        }

        /// Where dabs can leave paint.
        private static func area(of dabs: [BrushDab]) -> CGRect {
            dabs.reduce(CGRect.null) { $0.union($1.reach) }
        }
    }
}

extension Stroke {
    /// The last point up to which the stroke's dabs can no longer change as
    /// it grows: every width up to it settled. Zero when none are.
    func stablePoints(widths: [Double]) -> Int {
        guard points.count > 1, points.contains(where: { $0.location != points[0].location }) else { return 0 }
        // A point's pace is taken over the three after it.
        var last = points.count - 1 - (settings.dynamics.speed > 0 ? 3 : 0)
        let taper = min(max(settings.dynamics.taper, 0), 1)
        if taper > 0 {
            // Until the stroke is twice the taper long, the taper changes
            // all along it; after, only the end tapers anew.
            let reach = taper * settings.size * 8
            var distances = [0.0]
            for index in 1..<points.count {
                let from = points[index - 1].location, to = points[index].location
                distances.append(distances[index - 1] + hypot(to.x - from.x, to.y - from.y))
            }
            let total = distances[distances.count - 1]
            guard total >= reach * 2 else { return 0 }
            last = min(last, distances.lastIndex { $0 <= total - reach } ?? 0)
        }
        return max(last, 0)
    }
}

/// Canvas-aligned tiles a stroke is drawn into a little at a time, each
/// made into an image again only when drawn into.
private final class TiledRaster {
    private static let side = 256
    private struct Index: Hashable {
        var x, y: Int
    }
    private var contexts: [Index: CGContext] = [:]
    private var made: [Index: CGImage] = [:]

    /// Stamps `dabs` into the tiles they reach.
    func draw(_ dabs: [BrushDab], of stroke: Stroke, color: RGBAColor, canvasSize: CGSize) {
        var reaching: [Index: [BrushDab]] = [:]
        var order: [Index] = []
        for dab in dabs {
            for index in indices(over: dab.reach.intersection(CGRect(origin: .zero, size: canvasSize))) {
                if reaching[index] == nil { order.append(index) }
                reaching[index, default: []].append(dab)
            }
        }
        for index in order {
            guard let context = context(at: index), let dabs = reaching[index] else { continue }
            stroke.stamp(dabs, in: context, color: color)
            made[index] = nil
        }
    }

    /// Puts `image` in place of whatever covers `rect`.
    func replace(_ rect: CGRect, with image: CGImage) {
        for index in indices(over: rect) {
            guard let context = context(at: index) else { continue }
            context.saveGState()
            context.clip(to: rect)
            context.setBlendMode(.copy)
            Bitmap.draw(image, in: rect, context: context)
            context.restoreGState()
            made[index] = nil
        }
    }

    var images: [(rect: CGRect, image: CGImage)] {
        contexts.compactMap { index, context in
            let image = made[index] ?? context.makeImage()
            made[index] = image
            let side = Double(Self.side)
            return image.map { (CGRect(x: Double(index.x) * side, y: Double(index.y) * side, width: side, height: side), $0) }
        }
    }

    private func indices(over rect: CGRect) -> [Index] {
        guard !rect.isNull, !rect.isEmpty else { return [] }
        let side = Double(Self.side)
        let columns = Int((rect.minX / side).rounded(.down))...Int(((rect.maxX - 0.001) / side).rounded(.down))
        let rows = Int((rect.minY / side).rounded(.down))...Int(((rect.maxY - 0.001) / side).rounded(.down))
        return rows.flatMap { y in columns.map { Index(x: $0, y: y) } }
    }

    /// The tile's context, drawn into in canvas coordinates.
    private func context(at index: Index) -> CGContext? {
        if let context = contexts[index] { return context }
        guard let context = Bitmap.context(width: Self.side, height: Self.side) else { return nil }
        context.translateBy(x: -Double(index.x * Self.side), y: -Double(index.y * Self.side))
        contexts[index] = context
        return context
    }
}
