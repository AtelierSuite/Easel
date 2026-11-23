import CoreGraphics
import Paintbrush
import SwiftUI

/// A selection being resized, moved or bent by its handles. Each change is
/// worked out from the selection as it was when the handles were first
/// taken hold of, so nothing is lost to being redrawn again and again.
struct SelectionTransformSession {
    var original: Selection
    /// The box round `original`'s shape, which the grid starts on.
    var box: CGRect
    /// Sixteen points, four rows of four, that `box` is stretched onto.
    var points: [CGPoint]
    /// The selection last made from the grid; the session lasts while the
    /// selection is still this one.
    var result: Selection

    var shape: WarpShape { .warp(points) }

    static func grid(over box: CGRect) -> [CGPoint] {
        (0..<16).map { index in
            CGPoint(x: box.minX + box.width * Double(index % 4) / 3, y: box.minY + box.height * Double(index / 4) / 3)
        }
    }

    /// The box round the grid's points.
    var bounds: CGRect { Self.bounds(of: points) }

    static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The points that move with the one at `index` when warping: a
    /// corner's neighbours go with it so its curves keep their shape.
    static func pointsMoving(with index: Int) -> [Int] {
        let row = index / 4, column = index % 4
        guard (row == 0 || row == 3) && (column == 0 || column == 3) else { return [index] }
        let nextRow = row == 0 ? 1 : 2, nextColumn = column == 0 ? 1 : 2
        return [index, row * 4 + nextColumn, nextRow * 4 + column, nextRow * 4 + nextColumn]
    }
}

/// A drag on the selection's handles in progress.
struct SelectionHandleDrag {
    var start: CGPoint
    /// The grid as the drag found it.
    var origin: [CGPoint]
    /// Which grid points follow the pointer; all of them for a move.
    var moving: [Int]
    /// A side or corner of the box being pulled, and the box it began as.
    var resize: (side: (x: Int, y: Int), box: CGRect)?
    var hasMoved = false
}

extension EditorState {
    /// The grid the selection's handles sit on, while the Select tool is in
    /// hand and nothing else is being drawn.
    var selectionHandleGrid: [CGPoint]? {
        guard tool == .select, draftSelection == nil, selectionEditDraft == nil, let selection else { return nil }
        if let session = selectionTransform, session.result == selection { return session.points }
        let box = selection.shapeBounds
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        return SelectionTransformSession.grid(over: box)
    }

    /// How far outside the grid the resize handles sit, in canvas pixels:
    /// on the box when resizing, clear of the grid's corners when warping.
    var selectionResizeMargin: CGFloat {
        selectionWarps ? TransformDraft.resizeMargin / max(viewport.scale, 0.0001) : 0
    }

    /// The eight resize handles round the grid.
    func selectionResizeHandles(for grid: [CGPoint]) -> [TransformResizeHandle] {
        let bounds = SelectionTransformSession.bounds(of: grid)
        guard !bounds.isNull else { return [] }
        let box = bounds.insetBy(dx: -selectionResizeMargin, dy: -selectionResizeMargin)
        return TransformResizeHandle.all.map { handle in
            var handle = handle
            handle.location = CGPoint(
                x: box.midX + CGFloat(handle.side.x) * box.width / 2,
                y: box.midY + CGFloat(handle.side.y) * box.height / 2
            )
            return handle
        }
    }

    /// Takes hold of a handle, or of the selection to move it, if the
    /// pointer came down on one. False leaves the touch to draw with.
    func beginSelectionHandleDrag(at point: CGPoint) -> Bool {
        guard let grid = selectionHandleGrid, let selection else { return false }
        let reach = 22 / max(viewport.scale, 0.0001)
        func distance(_ handle: CGPoint) -> CGFloat { hypot(handle.x - point.x, handle.y - point.y) }
        var drag: SelectionHandleDrag?
        let nearestResize = selectionResizeHandles(for: grid).min { distance($0.location) < distance($1.location) }
        let nearestPoint = selectionWarps ? grid.indices.min { distance(grid[$0]) < distance(grid[$1]) } : nil
        if let nearestPoint, distance(grid[nearestPoint]) <= reach,
           nearestResize.map({ distance(grid[nearestPoint]) <= distance($0.location) }) ?? true {
            drag = SelectionHandleDrag(start: point, origin: grid, moving: SelectionTransformSession.pointsMoving(with: nearestPoint))
        } else if let resize = nearestResize, distance(resize.location) <= reach {
            drag = SelectionHandleDrag(
                start: point, origin: grid, moving: Array(grid.indices),
                resize: (resize.side, SelectionTransformSession.bounds(of: grid))
            )
        } else if isInsideSelectionHandles(point, selection: selection, grid: grid) {
            drag = SelectionHandleDrag(start: point, origin: grid, moving: Array(grid.indices))
        }
        guard let drag else { return false }
        if selectionTransform?.result != selection {
            let box = selection.shapeBounds
            selectionTransform = SelectionTransformSession(
                original: selection, box: box, points: SelectionTransformSession.grid(over: box), result: selection
            )
        }
        selectionHandleDrag = drag
        return true
    }

    /// Whether a drag from `point` moves the selection: from inside its
    /// shape, or inside the bent grid when warping.
    private func isInsideSelectionHandles(_ point: CGPoint, selection: Selection, grid: [CGPoint]) -> Bool {
        if selection.shapeContains(point) { return true }
        guard selectionWarps else { return false }
        let shape = WarpShape.warp(grid)
        let steps = 16
        let outline = CGMutablePath()
        outline.addLines(between:
            (0...steps).map { shape.point(Double($0) / Double(steps), 0) }
                + (0...steps).map { shape.point(1, Double($0) / Double(steps)) }
                + (0...steps).reversed().map { shape.point(Double($0) / Double(steps), 1) }
                + (0...steps).reversed().map { shape.point(0, Double($0) / Double(steps)) }
        )
        outline.closeSubpath()
        return outline.contains(point)
    }

    func continueSelectionHandleDrag(to point: CGPoint) {
        guard var drag = selectionHandleDrag, var session = selectionTransform else { return }
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        // Barely moved, it may still be a tap.
        if !drag.hasMoved {
            guard hypot(dx, dy) * viewport.scale >= 3 else { return }
            drag.hasMoved = true
            selectionHandleDrag = drag
        }
        if let resize = drag.resize {
            var box = resize.box
            let minimum: CGFloat = 1
            if resize.side.x < 0 { box = CGRect(x: min(box.minX + dx, box.maxX - minimum), y: box.minY, width: max(box.width - dx, minimum), height: box.height) }
            if resize.side.x > 0 { box.size.width = max(box.width + dx, minimum) }
            if resize.side.y < 0 { box = CGRect(x: box.minX, y: min(box.minY + dy, box.maxY - minimum), width: box.width, height: max(box.height - dy, minimum)) }
            if resize.side.y > 0 { box.size.height = max(box.height + dy, minimum) }
            session.points = TransformDraft.resized(drag.origin, from: resize.box, to: box)
        } else {
            for index in drag.moving {
                session.points[index] = CGPoint(x: drag.origin[index].x + dx, y: drag.origin[index].y + dy)
            }
        }
        selectionTransform = session
        selectionOutlinePreview = session.original.warpedOutline(from: session.box, to: session.shape, canvasSize: composition.size)
    }

    /// Lets go of the handles, making the selection the grid now gives.
    func endSelectionHandleDrag() {
        guard let drag = selectionHandleDrag, let session = selectionTransform else {
            cancelSelectionHandleDrag()
            return
        }
        selectionHandleDrag = nil
        guard drag.hasMoved else {
            selectionOutlinePreview = nil
            return
        }
        let size = composition.size
        if session.original.warpsQuickly {
            finishSelectionTransform(session, result: session.original.warped(from: session.box, to: session.shape, canvasSize: size))
            return
        }
        // A mask is redrawn off the main thread; its outline stays in the
        // meantime.
        enqueue({ PickedWarp(selection: session.original.warped(from: session.box, to: session.shape, canvasSize: size)) },
                apply: { [weak self] picked in
            guard let self, selectionTransform?.points == session.points else { return }
            finishSelectionTransform(session, result: picked.selection)
        })
    }

    private func finishSelectionTransform(_ session: SelectionTransformSession, result: Selection?) {
        selectionOutlinePreview = nil
        guard let result else {
            selection = nil
            selectionTransform = nil
            return
        }
        var session = session
        session.result = result
        selection = result
        selectionTransform = session
    }

    /// Puts the handles back where the drag found them.
    func cancelSelectionHandleDrag() {
        if let drag = selectionHandleDrag, drag.hasMoved, var session = selectionTransform {
            session.points = drag.origin
            selectionTransform = session
        }
        selectionHandleDrag = nil
        selectionOutlinePreview = nil
    }
}

/// A selection bent off the main thread, or nothing left selected.
private struct PickedWarp: Sendable {
    var selection: Selection?
}

// MARK: - Trying a feather, grow or shrink

/// A change to the whole selection being tried at a size picked on a
/// slider, before it is applied.
struct SelectionEditDraft: Equatable {
    var modification: SelectionModification
    var size: Double
    /// The largest size the slider goes to.
    var limit: Double
}

/// A selection edit as it would come out, worked out small: the picture
/// shaded where it would not be selected, and the new outline.
struct SelectionEditPreview: @unchecked Sendable {
    // Unchecked: `CGImage` and `CGPath` are immutable once made.
    var shade: CGImage
    var outline: CGPath
    var draft: SelectionEditDraft
}

extension EditorState {
    func beginSelectionEditDraft(_ modification: SelectionModification) {
        guard selection != nil else { return }
        let longest = max(composition.size.width, composition.size.height)
        let limit = min(250, max(10, (longest / 8).rounded()))
        selectionEditDraft = SelectionEditDraft(
            modification: modification, size: min(defaultSize(for: .modify(modification)), limit), limit: limit
        )
        updateSelectionEditPreview()
    }

    func setSelectionEditSize(_ size: Double) {
        guard var draft = selectionEditDraft else { return }
        draft.size = min(max(size, 0), draft.limit)
        guard draft != selectionEditDraft else { return }
        selectionEditDraft = draft
        updateSelectionEditPreview()
    }

    /// Works out how the edit would look, small and off the main thread;
    /// only the newest is kept.
    func updateSelectionEditPreview() {
        guard let draft = selectionEditDraft, let selection else {
            selectionEditPreview = nil
            return
        }
        let size = composition.size
        selectionEditPreviewTask?.cancel()
        selectionEditPreviewTask = Task { @MainActor in
            let preview = await Task.detached(priority: .userInitiated) { () -> SelectionEditPreview? in
                guard !Task.isCancelled else { return nil }
                return Self.selectionEditPreview(of: selection, draft: draft, canvasSize: size)
            }.value
            guard !Task.isCancelled, let preview, selectionEditDraft == draft else { return }
            selectionEditPreview = preview
        }
    }

    nonisolated static func selectionEditPreview(
        of selection: Selection, draft: SelectionEditDraft, canvasSize: CGSize
    ) -> SelectionEditPreview? {
        let scale = min(1, 1024 / max(canvasSize.width, canvasSize.height, 1))
        let small = CGSize(width: max(1, (canvasSize.width * scale).rounded()), height: max(1, (canvasSize.height * scale).rounded()))
        let shrunk = selection.applying(CGAffineTransform(scaleX: small.width / canvasSize.width, y: small.height / canvasSize.height), canvasSize: small)
        let edited = draft.size > 0
            ? shrunk.modified(draft.modification, radius: draft.size * scale, canvasSize: small)
            : shrunk
        let width = Int(small.width), height = Int(small.height)
        let coverage = edited?.coverage(width: width, height: height) ?? [UInt8](repeating: 0, count: width * height)
        // Darkened where unselected, partly where partly selected.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in coverage.indices {
            rgba[index * 4 + 3] = UInt8((Double(255 - coverage[index]) * 0.55).rounded())
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let shade = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        var back = CGAffineTransform(scaleX: canvasSize.width / small.width, y: canvasSize.height / small.height)
        let outline = edited.flatMap { $0.path(in: small).copy(using: &back) } ?? CGMutablePath()
        return SelectionEditPreview(shade: shade, outline: outline, draft: draft)
    }

    func applySelectionEditDraft() {
        guard let draft = selectionEditDraft else { return }
        closeSelectionEditDraft()
        guard draft.size > 0 else { return }
        perform(.modify(draft.modification), size: draft.size)
    }

    func closeSelectionEditDraft() {
        selectionEditPreviewTask?.cancel()
        selectionEditDraft = nil
        selectionEditPreview = nil
    }
}
