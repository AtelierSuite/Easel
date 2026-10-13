import SwiftUI

/// A file that must be saved as a copy before it is edited: whether it still
/// has to be, and how to save the copy, reporting whether one was saved.
struct CopyBeforeEditing {
    var isRequired: () -> Bool
    var save: (_ completion: @escaping (_ saved: Bool) -> Void) -> Void
}

/// Everything about an editing session that is not part of the picture
/// itself: the tool in hand, its settings, the selection, the view onto the
/// canvas, and edits still being worked out.
@MainActor
@Observable
final class EditorState {
    // MARK: Tools

    var tool: Tool = .brush {
        didSet { toolDidChange(from: oldValue) }
    }
    var activeLayerID: Layer.ID? {
        didSet {
            if activeLayerID != oldValue {
                isEditingMask = false
                isEditingFilterMask = false
                activeGroupID = nil
                if tool == .transform { cancelTransform() }
            }
        }
    }
    /// A group picked in the Layers panel, which the Move tool moves whole.
    var activeGroupID: UUID?
    /// Whether painting goes into the active layer's mask rather than its
    /// pixels: the brush hides, the eraser reveals.
    var isEditingMask = false {
        didSet { if isEditingMask { isEditingFilterMask = false } }
    }
    /// Whether painting goes into the active layer's filter mask: the brush
    /// hides the filters, the eraser brings them back.
    var isEditingFilterMask = false {
        didSet { if isEditingFilterMask { isEditingMask = false } }
    }
    var brush = BrushSettings(size: 24, color: .black)
    var eraser = BrushSettings(size: 60, softness: 0.3)
    /// For the retouching brushes, opacity is strength: how far a smear
    /// carries, how blurred or how coarse the tiles, how fully a spot heals.
    var liquifyBrush = BrushSettings(size: 120, opacity: 0.6, softness: 0.5, usesPressure: false)
    var censorBrush = BrushSettings(size: 80, opacity: 0.5, softness: 0.5, usesPressure: false)
    var censorKind: CensorKind = .gaussianBlur {
        didSet {
            guard censorKind != oldValue else { return }
            activeStroke = nil
            smudge = nil
            retouchEffect = nil
            dockedEdge = nil
        }
    }
    /// Motion blur direction in degrees.
    var censorAngle = 0.0
    /// For the Tone tool, opacity is how much each stroke does.
    var toneBrush = BrushSettings(size: 80, opacity: 0.3, softness: 0.6, usesPressure: false)
    var toneKind: ToneKind = .dodge {
        didSet { if toneKind != oldValue { retouchEffect = nil } }
    }
    var isSmudging: Bool { tool == .censor && censorKind == .smudge }
    var healBrush = BrushSettings(size: 40, softness: 0.3, usesPressure: false)
    var cloneBrush = BrushSettings(size: 60, softness: 0.4, usesPressure: false)
    /// Where the clone stamp copies from, in canvas pixels. It moves with
    /// the brush, so after a stroke it sits as far from where the stroke
    /// ended as it was from where it began.
    var cloneSource: CGPoint?
    /// How far the copy is from the brush. Set by the first stroke after the
    /// source is picked and kept for later ones, so separate strokes go on
    /// copying the same picture.
    var cloneOffset: CGVector?
    /// Whether the next tap picks the clone stamp's source.
    var isPickingCloneSource = false
    var fillTolerance = 0.12
    /// Whether the fill tool and Fill Selection lay down a pattern rather
    /// than the brush colour.
    var fillsWithPattern = false
    var fillPattern = PatternChoice()
    /// Whether the brush and eraser paint mirrored copies of each stroke.
    var symmetry: Symmetry = .off
    /// The straightedge strokes run along, when it is out.
    var ruler: Ruler?
    /// How the ruler was turned when fingers came down to turn it.
    @ObservationIgnored var rulerTurnStart = 0.0
    /// The ruler's edge the stroke under the finger runs along.
    var dockedEdge: Ruler.Edge?
    /// Whether moved layers snap to the canvas's edges and middle.
    var snaps = true
    /// What a layer being moved has snapped to.
    var snapLines: [SnapLine] = []
    /// Whether rulers run along the canvas.
    var showsRulers = false
    /// Whether the canvas shows the picture as it was opened, for comparing.
    var isComparing = false
    /// Where Apple Pencil or the pointer hovers over the canvas.
    var hoverPoint: CGPoint?
    /// A guide being pulled out of a ruler.
    var draftGuide: Guide?
    /// The guide the Move tool is dragging.
    @ObservationIgnored var draggedGuide: Guide.ID?
    var gradientOpacity = 1.0
    var gradientKind: PaintGradient.Kind = .linear
    /// The Gradient tool's colours; nil for the brush colour fading out.
    var gradientStops: [PaintGradient.Stop]?
    var shapeKind: ShapeSpec.Kind = .rectangle
    var shapeIsFilled = false
    var shapeLineWidth = 12.0
    var shapeCornerRadius = 24.0
    var shapeSides = 6
    var shapeInnerRatio = 0.45
    var selectionKind: SelectionKind = .rectangle
    /// How a new selection meets the one already there.
    var selectionMode: SelectionMode = .replace
    /// A change to the selection waiting for its size to be given.
    var pendingSelectionEdit: SelectionEdit?
    /// How different a colour may be and still be picked by magic select.
    var selectionTolerance = 0.15
    /// Set while the Adjustments panel waits for a tap on something that
    /// should be grey, to balance the picture's colour by it.
    @ObservationIgnored var neutralPick: ((RGBAColor) -> Void)?
    var isPickingNeutral = false
    /// Whether magic select picks only the run of colour touching the tap,
    /// or that colour anywhere in the picture.
    var selectsContiguously = true
    /// The picture's edges, for magnetic select to cling to; worked out
    /// when a magnetic drag starts.
    @ObservationIgnored var edgeMap: EdgeMap?
    @ObservationIgnored private var edgeMapSource: Composition?
    var cropAspect: CropAspect = .free {
        didSet { constrainCropRect() }
    }

    /// The colour brushes, fills, shapes and new text use.
    var color: RGBAColor {
        get { brush.color }
        set { brush.color = newValue.withAlpha(1) }
    }

    // MARK: Selection and drafts

    var selection: Selection?
    /// A stroke still under the finger.
    var activeStroke: Stroke?
    /// Strokes lifted but not yet painted into their layer, drawn over it
    /// in the meantime so nothing flickers.
    var pendingStrokes: [PendingStroke] = []
    /// The blur or mosaic the blur and mosaic brushes reveal.
    var retouchEffect: RetouchPreparation?
    /// A smear being made.
    var smudge: SmudgeSession?
    /// The path the pen is adding points to.
    var penPath: VectorPathRef?
    /// Whether a new pen path joins the active vector layer rather than
    /// starting a layer of its own.
    var penAddsToLayer = true
    /// The point picked out for editing.
    var selectedNode: VectorNodeRef?
    /// Points picked alongside it, which move and go with it.
    var additionalNodes: [VectorNodeRef] = []
    /// Whether tapping a point adds it to those picked.
    var isSelectingMultiplePoints = false
    /// The Shape Builder at work on a vector layer's overlapping shapes.
    var shapeBuilder: ShapeBuilderSession?
    /// The smart object layer whose contents are open for editing.
    var editingSmartObject: SmartObjectEditing?
    /// An edit waiting on the file being saved as a copy first, which the
    /// person is asked about; see `copyBeforeEditing`.
    var heldEdit: (() -> Void)? {
        didSet { isAskingToCopy = heldEdit != nil }
    }
    /// Whether the person is being asked about the held edit.
    var isAskingToCopy = false
    @ObservationIgnored var vectorDrag: VectorDrag?
    /// The vector layer as it was when the drag began, to go back to if
    /// the drag is called off.
    @ObservationIgnored var vectorDragOrigin: Layer?
    var draftSelection: Selection?
    var draftShape: ShapeSpec?
    var draftGradient: (start: CGPoint, end: CGPoint)?
    /// The crop tool's frame, in canvas pixels; nil until the tool is picked.
    var cropRect: CGRect?
    var cropMode: CropMode = .frame {
        didSet {
            draftStraighten = nil
            perspectiveQuad = cropMode == .perspective ? Self.startingQuad(in: read().canvasRect) : nil
        }
    }
    /// The four corners a perspective crop flattens, clockwise from the top
    /// left, in canvas pixels.
    var perspectiveQuad: [CGPoint]?
    @ObservationIgnored private var quadDrag: (corner: Int, start: CGPoint, origin: CGPoint)?
    /// The line being drawn to straighten the picture along.
    var draftStraighten: (start: CGPoint, end: CGPoint)?
    /// The layer the Transform tool is bending, and how.
    var transformDraft: TransformDraft?
    var transformMode: TransformMode = .distort
    /// The bent layer as it will look, canvas-aligned and shrunk.
    var transformPreview: LayerPreview?
    @ObservationIgnored var transformDrag: TransformDrag?
    @ObservationIgnored var transformPreviewTask: Task<Void, Never>?

    // MARK: View

    /// 1 shows the whole canvas fitted to the screen.
    var zoom: Double = 1
    var pan: CGSize = .zero
    /// How far the view is turned, in radians clockwise, about its middle.
    var rotation: Double = 0
    /// Whether two fingers turning on the canvas turn the view.
    var rotatesWithGestures = UserDefaults.standard.object(forKey: EditorState.rotatesWithGesturesKey) as? Bool
        ?? true {
        didSet {
            UserDefaults.standard.set(rotatesWithGestures, forKey: Self.rotatesWithGesturesKey)
            if !rotatesWithGestures { rotate(by: -rotation, around: viewport.center) }
        }
    }
    private static let rotatesWithGesturesKey = "RotatesCanvasWithGestures"
    static let zoomRange: ClosedRange<Double> = 0.25...32
    /// The size of the area the canvas is drawn in.
    var viewportSize: CGSize = .zero
    /// Room kept clear around the canvas for the tool bars over it.
    var canvasInsets = EdgeInsets()

    // MARK: Panels and progress

    var presentedPanel: EditorPanel?
    /// On iPad, whether the inspector beside the canvas is open.
    var isInspectorPresented = true
    /// A stand-in for one layer's pixels while an adjustment or filter is
    /// being tried; shown until it is applied or abandoned.
    var layerPreview: LayerPreview?
    var isImportingFiles = false
    var errorMessage: String?
    /// How many edits are being worked on off the main thread.
    private(set) var runningJobs = 0
    var isBusy: Bool { runningJobs > 0 }

    /// The picture being edited. Kept here as well as in the host's binding:
    /// a document's binding hands back its old value until the next update,
    /// so an edit that reads straight after another would undo it.
    private(set) var composition: Composition = .blank()
    /// Hands each edit on to the host, which keeps or saves it.
    @ObservationIgnored private var publish: (Composition) -> Void = { _ in /* Replaced on attach. */ }
    /// What was handed to the host lately, newest last. A document reports
    /// its value back some time after it is set, so during a drag it can
    /// report a step the editor has already moved past — or, after an undo,
    /// one the undo took away. Those are echoes, not changes.
    @ObservationIgnored private var recentlyPublished: [Composition] = []
    @ObservationIgnored private var hasSizedBrushes = false
    /// The picture the latest write replaced.
    @ObservationIgnored private var replaced: Composition?
    /// The selection on each side of the latest changes to the canvas —
    /// turning, flipping, resizing, cropping — which an undo or redo across
    /// one puts back with the picture.
    @ObservationIgnored private var canvasSelections: [(composition: Composition, selection: Selection?)] = []
    /// Set by a host whose file is never edited in place: until a copy is
    /// saved, each edit is held back and the person asked first.
    @ObservationIgnored var copyBeforeEditing: CopyBeforeEditing?
    /// Told of every change made here, which is what undo records. Changes
    /// the host makes — such as a document reading itself back after its
    /// first save — are not edits and are not undoable.
    @ObservationIgnored var edited: (_ old: Composition, _ new: Composition) -> Void = { _, _ in
        // Replaced by the editor view.
    }
    /// Where edits worked out off the main thread wait their turn, so each
    /// starts from the result of the one before.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var moveOrigin: MoveOrigin?
    @ObservationIgnored private var groupMoveOrigin: (start: CGPoint, layers: [(Layer.ID, LayerTransform)])?
    @ObservationIgnored private var cropDrag: CropDrag?
    /// The adjustment or filter preview being worked out, which a newer one
    /// replaces.
    @ObservationIgnored var previewTask: Task<Void, Never>?
    /// For each layer with filters, its newest filtered pixels and what they
    /// were worked out from. Kept on screen while newer ones are worked out,
    /// and observed, so the canvas redraws as each arrives.
    private var filteredDisplay: [Layer.ID: (key: FilterCache.Key, image: CGImage)] = [:]
    /// The filtering each layer is waiting for. Only the newest is kept: a
    /// slider being dragged asks far faster than filters can run.
    @ObservationIgnored private var wantedFilters: [Layer.ID: (key: FilterCache.Key, source: LayerImage, filterMask: LayerMask?)] = [:]
    @ObservationIgnored private var filteringLayers: Set<Layer.ID> = []
    /// The same for layers with effects.
    private var styledDisplay: [Layer.ID: (key: StyleCache.Key, styled: StyledLayer)] = [:]
    @ObservationIgnored private var wantedStyles: [Layer.ID: (key: StyleCache.Key, layer: Layer)] = [:]
    @ObservationIgnored private var stylingLayers: Set<Layer.ID> = []

    struct PendingStroke: Identifiable {
        let id = UUID()
        var layerID: Layer.ID
        var stroke: Stroke
        /// Painted into the layer's mask rather than its pixels.
        var isMask = false
        /// Painted into the layer's filter mask.
        var isFilterMask = false
    }

    struct LayerPreview {
        var layerID: Layer.ID
        var image: CGImage
    }

    private struct MoveOrigin {
        var layerID: Layer.ID
        var start: CGPoint
        var transform: LayerTransform
    }

    private struct CropDrag {
        /// Which edges move: -1 the minimum edge, 1 the maximum, 0 neither.
        var horizontal: Int
        var vertical: Int
        var start: CGPoint
        var rect: CGRect
    }

    init() {}

    // MARK: - Document access

    func read() -> Composition { composition }

    /// Replaces the picture and passes it to the host.
    func write(_ composition: Composition) {
        if holdsEdits {
            heldEdit = { [weak self] in self?.write(composition) }
            return
        }
        let previous = self.composition
        replaced = previous
        self.composition = composition
        recentlyPublished.append(composition)
        if recentlyPublished.count > 64 { recentlyPublished.removeFirst(recentlyPublished.count - 64) }
        publish(composition)
        edited(previous, composition)
    }

    func attach(to composition: Composition, publish: @escaping (Composition) -> Void) {
        self.publish = publish
        if !hasSizedBrushes {
            sizeBrushes(for: composition.size)
            hasSizedBrushes = true
        }
        self.composition = composition
        if activeLayerID.flatMap({ composition.index(of: $0) }) == nil {
            activeLayerID = composition.layers.last?.id
        }
    }

    /// The brush sizes above suit a canvas about a thousand pixels across;
    /// a 12-megapixel photo needs them several times larger to make the
    /// same mark on screen.
    private func sizeBrushes(for canvasSize: CGSize) {
        resizeBrushes(by: max(0.5, max(canvasSize.width, canvasSize.height) / 1024))
    }

    /// Scales every brush, as when a picture replaces the canvas it was
    /// sized for.
    func resizeBrushes(by factor: Double) {
        func scaled(_ settings: inout BrushSettings) {
            settings.size = min(BrushSettings.sizeRange.upperBound, (settings.size * factor).rounded())
        }
        scaled(&brush)
        scaled(&eraser)
        scaled(&liquifyBrush)
        scaled(&censorBrush)
        scaled(&toneBrush)
        scaled(&healBrush)
        scaled(&cloneBrush)
        shapeLineWidth = (shapeLineWidth * factor).rounded()
    }

    /// Takes in a change the host made, such as an undo, or the host catching
    /// up with an edit made here.
    func sync(_ composition: Composition) {
        guard composition != self.composition else { return }
        if recentlyPublished.contains(composition) {
            // Behind the editor: either a late report of an earlier step, or
            // the system's own undo stepping the document back. Either way
            // the editor's picture is the real one, and the file must say so.
            publish(self.composition)
            return
        }
        self.composition = composition
        if activeLayerID.flatMap({ composition.index(of: $0) }) == nil {
            activeLayerID = composition.layers.last?.id
        }
    }

    /// Notes the selection before and after a change to the canvas, made
    /// from `before` while `selection` was selected.
    func noteCanvasChange(from before: Composition, selection previous: Selection?) {
        canvasSelections.append((before, previous))
        canvasSelections.append((composition, selection))
        let limit = 2 * (CompositionHistory.levels + 1)
        if canvasSelections.count > limit { canvasSelections.removeFirst(canvasSelections.count - limit) }
    }

    /// Whether an edit has to wait for the file to be saved as a copy.
    var holdsEdits: Bool { copyBeforeEditing?.isRequired() == true }

    /// Saves the copy the held edit is waiting on, then makes the edit, or
    /// drops it if no copy was saved.
    func saveCopyForHeldEdit() {
        guard let copyBeforeEditing else { return }
        let save = {
            copyBeforeEditing.save { [weak self] saved in
                guard let self else { return }
                let edit = heldEdit
                heldEdit = nil
                if saved { edit?() }
            }
        }
        guard presentedPanel != nil else {
            save()
            return
        }
        // A panel's sheet goes down first; nothing else can come up over it.
        presentedPanel = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            save()
        }
    }

    /// Changes the picture.
    func update(_ change: (inout Composition) -> Void) {
        var composition = read()
        change(&composition)
        write(composition)
    }

    var activeLayer: Layer? {
        activeLayerID.flatMap { read()[$0] }
    }

    func updateActiveLayer(_ change: (inout Layer) -> Void) {
        guard let id = activeLayerID else { return }
        update { composition in
            guard var layer = composition[id] else { return }
            change(&layer)
            composition[id] = layer
        }
    }

    /// After an undo or redo, lets go of whatever the change took away.
    func showRestored(_ composition: Composition) {
        if activeLayerID.flatMap({ composition.index(of: $0) }) == nil {
            activeLayerID = composition.layers.last?.id
        }
        pendingStrokes.removeAll { composition.index(of: $0.layerID) == nil }
        if let preview = layerPreview, composition.index(of: preview.layerID) == nil { layerPreview = nil }
        if tool == .crop { cropRect = composition.canvasRect }
        if tool == .transform { cancelTransform() }
        if let replaced, canvasSelections.contains(where: { $0.composition == replaced }),
           let kept = canvasSelections.last(where: { $0.composition == composition }) {
            // Across a change to the canvas, the selection goes back with it.
            selection = kept.selection
        } else if let selection, !composition.canvasRect.intersects(selection.bounds(in: composition.size)) {
            self.selection = nil
        }
        if let groupID = activeGroupID, composition.group(groupID) == nil { activeGroupID = nil }
        func resolves(_ ref: VectorNodeRef) -> Bool {
            guard let paths = composition[ref.layerID]?.vector?.paths, paths.indices.contains(ref.path) else { return false }
            return paths[ref.path].nodes.indices.contains(ref.node)
        }
        if let node = selectedNode, !resolves(node) { selectedNode = nil }
        additionalNodes.removeAll { !resolves($0) }
        if let path = penPath, composition[path.layerID]?.vector?.paths.indices.contains(path.path) != true {
            penPath = nil
        }
        // Its regions were cut from paths the change may have taken away.
        shapeBuilder = nil
        vectorDrag = nil
        vectorDragOrigin = nil
    }

    // MARK: - Filtered layers

    /// Longest side of the copy a filtered layer is shown from: plenty for a
    /// screen, and small enough for filters to follow a slider.
    nonisolated static let filterDisplaySize = 3000

    /// What to show for a layer: its own pixels, or — when it has filters —
    /// the newest filtered copy ready, asking for a fresher one if needed.
    func displayImage(for layer: Layer) -> CGImage {
        guard layer.hasActiveFilters else { return layer.image.cgImage }
        let key = FilterCache.Key(layer: layer, maxPixelSize: Self.filterDisplaySize)
        let shown = filteredDisplay[layer.id]
        if let shown, shown.key == key { return shown.image }
        requestFiltering(layer.id, key: key, source: layer.image, filterMask: layer.activeFilterMask)
        return shown?.image ?? layer.image.cgImage
    }

    private func requestFiltering(_ layerID: Layer.ID, key: FilterCache.Key, source: LayerImage, filterMask: LayerMask?) {
        // Asked for during a canvas update: only note it here, and start the
        // work once the update is over.
        wantedFilters[layerID] = (key, source, filterMask)
        guard filteringLayers.insert(layerID).inserted else { return }
        Task { @MainActor in
            while let wanted = wantedFilters.removeValue(forKey: layerID) {
                let image = await Task.detached(priority: .userInitiated) {
                    FilterCache.shared.image(for: wanted.key, source: wanted.source, filterMask: wanted.filterMask)
                }.value
                filteredDisplay[layerID] = (wanted.key, image)
            }
            filteringLayers.remove(layerID)
        }
    }

    /// What to show for a layer with effects: the newest copy with them
    /// worked out, asking for a fresher one if needed. Nil for a layer
    /// without effects, or before the first copy is ready.
    func styledDisplay(for layer: Layer) -> StyledLayer? {
        guard layer.isStyled else { return nil }
        let key = StyleCache.Key(layer: layer, maxPixelSize: Self.filterDisplaySize)
        let shown = styledDisplay[layer.id]
        if let shown, shown.key == key { return shown.styled }
        wantedStyles[layer.id] = (key, layer)
        if stylingLayers.insert(layer.id).inserted {
            Task { @MainActor in
                while let wanted = wantedStyles.removeValue(forKey: layer.id) {
                    let styled = await Task.detached(priority: .userInitiated) {
                        StyleCache.shared.styled(for: wanted.key, layer: wanted.layer)
                    }.value
                    styledDisplay[layer.id] = (wanted.key, styled)
                }
                stylingLayers.remove(layer.id)
            }
        }
        return shown?.styled
    }

    // MARK: - Viewport

    /// Where the canvas sits on screen.
    var viewport: CanvasViewport {
        CanvasViewport(
            canvasSize: read().size, viewportSize: viewportSize, insets: canvasInsets, zoom: zoom, pan: pan,
            rotation: rotation
        )
    }

    func zoom(by factor: Double, around anchor: CGPoint) {
        let before = viewport
        let canvasPoint = before.canvasPoint(anchor)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        // Keep the canvas point under the fingers where it was.
        let drifted = viewport.screenPoint(canvasPoint)
        pan(by: CGSize(width: anchor.x - drifted.x, height: anchor.y - drifted.y))
    }

    func pan(by translation: CGSize) {
        // The pan is taken before the turn, so a drag on screen is turned back.
        let level = CGPoint(x: translation.width, y: translation.height)
            .applying(CGAffineTransform(rotationAngle: -rotation))
        pan.width += level.x
        pan.height += level.y
    }

    /// Turns the view `angle` radians clockwise, keeping the canvas point
    /// under `anchor` where it was.
    func rotate(by angle: Double, around anchor: CGPoint) {
        let canvasPoint = viewport.canvasPoint(anchor)
        rotation = remainder(rotation + angle, 2 * .pi)
        if abs(rotation) < 0.0001 { rotation = 0 }
        let drifted = viewport.screenPoint(canvasPoint)
        pan(by: CGSize(width: anchor.x - drifted.x, height: anchor.y - drifted.y))
    }

    /// Settles a turn that ended near upright, or on its side, square.
    func settleRotation() {
        let quarter = Double.pi / 2
        let nearest = (rotation / quarter).rounded() * quarter
        guard rotation != nearest, abs(rotation - nearest) < Self.rotationSnap else { return }
        rotate(by: nearest - rotation, around: viewport.center)
    }

    /// How close to a quarter turn a turn has to end to settle on it.
    static let rotationSnap = 8 * Double.pi / 180

    func fitCanvas() {
        zoom = 1
        pan = .zero
        rotation = 0
    }

    /// Zooms to `newZoom` times the fitted size with `canvasPoint` in the
    /// middle of the clear area.
    func focus(on canvasPoint: CGPoint, zoom newZoom: Double) {
        zoom = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let size = read().size
        let scale = viewport.scale
        pan = CGSize(width: (size.width / 2 - canvasPoint.x) * scale, height: (size.height / 2 - canvasPoint.y) * scale)
    }

    /// Shows canvas pixels one for one with screen pixels.
    func zoomToActualSize(displayScale: Double) {
        let fit = viewport.fitScale
        guard fit > 0 else { return }
        zoom = min(max(1 / (fit * displayScale), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = .zero
    }

    // MARK: - Tools

    private func toolDidChange(from old: Tool) {
        shapeBuilder = nil
        guard tool != old else { return }
        penPath = nil
        activeStroke = nil
        smudge = nil
        draftShape = nil
        draftSelection = nil
        draftGradient = nil
        if tool == .crop {
            cropRect = read().canvasRect
            constrainCropRect()
        } else {
            cropRect = nil
        }
        if tool == .transform {
            beginTransformDraft()
        } else if old == .transform {
            transformPreviewTask?.cancel()
            transformDraft = nil
            transformPreview = nil
        }
    }

    /// The settings the brush, eraser or retouching brush in hand uses.
    var currentBrush: BrushSettings {
        get {
            switch tool {
            case .eraser: return eraser
            case .liquify: return liquifyBrush
            case .censor: return censorBrush
            case .tone: return toneBrush
            case .heal: return healBrush
            case .clone: return cloneBrush
            default: return brush
            }
        }
        set {
            switch tool {
            case .eraser: eraser = newValue
            case .liquify: liquifyBrush = newValue
            case .censor: censorBrush = newValue
            case .tone: toneBrush = newValue
            case .heal: healBrush = newValue
            case .clone: cloneBrush = newValue
            default: brush = newValue
            }
        }
    }

    /// The brush's outline under a hovering pencil or pointer, in canvas
    /// pixels, when the tool in hand paints with a brush.
    var brushOutline: (center: CGPoint, diameter: Double)? {
        guard let hoverPoint, activeStroke == nil, tool.usesStrokes || tool == .liquify else {
            return nil
        }
        return (hoverPoint, currentBrush.size)
    }

    /// What a stroke made with the tool in hand does.
    var strokeKind: Stroke.Kind {
        switch tool {
        case .eraser: return .erase
        case .censor:
            switch censorKind {
            case .gaussianBlur: return .blur
            case .mosaic: return .mosaic
            case .motionBlur: return .motionBlur(angle: censorAngle)
            case .smudge: return .paint
            }
        case .heal: return .heal
        case .tone: return .tone(toneKind)
        case .clone: return .clone(offset: cloneOffset ?? .zero)
        default: return .paint
        }
    }

    /// Why the active layer cannot be painted on, if it cannot: by the tool
    /// in hand, or, not `byTool`, by a command such as Fill that changes its
    /// pixels whatever the tool.
    func paintingBlocker(byTool: Bool = true) -> String? {
        guard let layer = activeLayer else { return String(localized: "Error.NoLayer") }
        if composition.isLocked(layer) { return String(localized: "Error.LayerLocked") }
        if editsAnyMask, ![Tool.brush, .eraser, .gradient].contains(tool) {
            return String(localized: "Error.MaskTool")
        }
        // Liquify bends a smart object through its Liquify filter instead.
        if layer.isSmartObject, byTool ? !editsAnyMask && tool.paintsPixels && tool != .liquify : true {
            return String(localized: "Error.SmartObject")
        }
        if !layer.isVisible || composition.ancestors(of: layer.groupID).contains(where: { !$0.isVisible }) {
            return String(localized: "Error.LayerHidden")
        }
        return nil
    }

    /// Whether painting goes into a mask right now.
    /// An adjustment layer has nothing else to paint on.
    var editsMask: Bool {
        !editsFilterMask && (isEditingMask || activeLayer?.isAdjustment == true) && activeLayer?.mask != nil
    }

    /// Whether painting goes into the active layer's filter mask right now.
    var editsFilterMask: Bool { isEditingFilterMask && activeLayer?.filterMask != nil }

    var editsAnyMask: Bool { editsMask || editsFilterMask }

    /// Selection outline for clipping, in canvas pixels.
    var selectionPath: CGPath? {
        selection.map { $0.path(in: read().size) }
    }

    // MARK: - Gestures

    /// A finger or pencil came down on the canvas.
    func toolBegan(
        at point: CGPoint, pressure: Double, azimuth: Double? = nil, altitude: Double? = nil, time: TimeInterval? = nil
    ) {
        // Touching down ends a hover.
        hoverPoint = nil
        if isPickingNeutral {
            isPickingNeutral = false
            if let color = CompositionRenderer.color(at: point, in: composition) { neutralPick?(color) }
            neutralPick = nil
            return
        }
        // An adjustment being tried stands in for the layer; painting under
        // it would be hidden, then lost when it is applied.
        guard layerPreview == nil else { return }
        if isSmudging {
            guard paintingBlocker() == nil else { return }
            beginSmudge(at: point)
            return
        }
        switch tool {
        case .brush, .eraser, .censor, .tone, .heal, .clone:
            guard paintingBlocker() == nil else { return }
            // Started beside the ruler, the whole stroke runs along it.
            dockedEdge = rulerEdge(near: point)
            let point = dockedEdge?.project(point) ?? point
            if tool == .clone {
                // Until there is a source, a touch only picks one.
                guard let source = cloneSource, !isPickingCloneSource else { return }
                if cloneOffset == nil { cloneOffset = CGVector(dx: source.x - point.x, dy: source.y - point.y) }
            }
            if editsAnyMask {
                // On a mask the brush hides and the eraser reveals.
                var settings = currentBrush
                settings.color = .white
                activeStroke = Stroke(
                    points: [StrokePoint(location: point, pressure: pressure, azimuth: azimuth, altitude: altitude, time: time)],
                    settings: settings, kind: tool == .brush ? .erase : .paint, clip: selection
                )
                return
            }
            if tool == .censor || tool == .clone || tool == .tone { prepareRetouchEffect() }
            activeStroke = Stroke(
                points: [StrokePoint(location: point, pressure: pressure, azimuth: azimuth, altitude: altitude, time: time)],
                settings: currentBrush, kind: strokeKind, clip: selection
            )
            if tool == .brush, currentBrush.tip == .oil, let layer = activeLayer,
               let pixels = Bitmap.pixels(of: layer.aligned(in: composition.size).image.cgImage) {
                // Oil paint mixes with the layer as it is now.
                activeStroke?.pickup = PaintSource(pixels: pixels)
            }
        case .liquify:
            guard paintingBlocker() == nil else { return }
            beginSmudge(at: point)
        case .move:
            // A guide under the finger moves before any layer does.
            if let guide = guide(near: point) {
                draggedGuide = guide.id
                return
            }
            if let groupID = activeGroupID, let group = composition.group(groupID) {
                guard !group.isLocked else { return }
                let members = composition.layers(in: groupID).filter { !composition.isLocked($0) }
                groupMoveOrigin = (point, members.map { ($0.id, $0.transform) })
                return
            }
            guard let layer = activeLayer, !composition.isLocked(layer) else { return }
            moveOrigin = MoveOrigin(layerID: layer.id, start: point, transform: layer.transform)
        case .select:
            guard selectionKind.isDrawn else { return }
            if selectionKind == .magnetic { prepareEdgeMap() }
            draftSelection = Selection(shape: shape(for: selectionKind, from: point, to: point))
        case .pen:
            penBegan(at: point)
        case .nodes:
            if shapeBuilder != nil {
                pickShapeBuilderFace(at: point)
                return
            }
            nodesBegan(at: point)
        case .transform:
            transformBegan(at: point)
        case .shape:
            draftShape = ShapeSpec(
                kind: shapeKind, start: point, end: point, isFilled: shapeIsFilled,
                lineWidth: shapeLineWidth, color: color, cornerRadius: shapeCornerRadius, sides: shapeSides,
                innerRatio: shapeInnerRatio
            )
        case .gradient:
            guard paintingBlocker() == nil else { return }
            draftGradient = (point, point)
        case .crop:
            if cropMode == .straighten {
                draftStraighten = (point, point)
            } else if cropMode == .perspective, let quad = perspectiveQuad {
                // The nearest corner follows the finger.
                let nearest = quad.indices.min {
                    hypot(quad[$0].x - point.x, quad[$0].y - point.y) < hypot(quad[$1].x - point.x, quad[$1].y - point.y)
                } ?? 0
                quadDrag = (nearest, point, quad[nearest])
            } else {
                beginCropDrag(at: point)
            }
        case .eyedropper:
            sampleColor(at: point)
        case .fill, .text:
            break
        }
    }

    func toolMoved(to points: [StrokePoint]) {
        guard let last = points.last else { return }
        if isSmudging {
            continueSmudge(to: points.map(\.location))
            return
        }
        switch tool {
        case .brush, .eraser, .censor, .tone, .heal, .clone:
            guard let edge = dockedEdge else {
                activeStroke?.points.append(contentsOf: points)
                return
            }
            activeStroke?.points.append(contentsOf: points.map { point in
                var docked = point
                docked.location = edge.project(point.location)
                return docked
            })
        case .liquify:
            continueSmudge(to: points.map(\.location))
        case .move:
            if let guide = draggedGuide {
                moveGuide(guide, to: last.location)
                return
            }
            if let group = groupMoveOrigin {
                var dx = last.location.x - group.start.x, dy = last.location.y - group.start.y
                let indices = Dictionary(
                    composition.layers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
                )
                let bounds = group.layers.reduce(CGRect.null) { bounds, member in
                    guard let index = indices[member.0] else { return bounds }
                    var layer = composition.layers[index]
                    layer.transform = member.1
                    return bounds.union(layer.bounds)
                }
                if !bounds.isNull {
                    let snap = snappedOffset(for: bounds.offsetBy(dx: dx, dy: dy))
                    dx += snap.dx
                    dy += snap.dy
                }
                update { composition in
                    for (id, transform) in group.layers {
                        guard let index = indices[id], composition.layers.indices.contains(index),
                              composition.layers[index].id == id else { continue }
                        var moved = transform
                        moved.position.x += dx
                        moved.position.y += dy
                        composition.layers[index].transform = moved
                    }
                }
                return
            }
            guard let origin = moveOrigin else { return }
            var transform = origin.transform
            transform.position.x += last.location.x - origin.start.x
            transform.position.y += last.location.y - origin.start.y
            if var layer = composition[origin.layerID] {
                layer.transform = transform
                let snap = snappedOffset(for: layer.bounds)
                transform.position.x += snap.dx
                transform.position.y += snap.dy
            }
            update { $0[origin.layerID]?.transform = transform }
        case .select:
            guard let draft = draftSelection else { return }
            switch draft.shape {
            case .lasso(let existing) where selectionKind == .magnetic:
                draftSelection = Selection(shape: .lasso(existing + magneticPoints(points.map(\.location), after: existing.last)))
            case .lasso(let existing):
                draftSelection = Selection(shape: .lasso(existing + points.map(\.location)))
            case .rectangle(let rect), .ellipse(let rect):
                draftSelection = Selection(shape: shape(for: selectionKind, from: rect.origin, to: last.location))
            case .mask:
                break
            }
        case .pen:
            penMoved(to: last.location)
        case .nodes:
            if shapeBuilder != nil {
                for point in points { pickShapeBuilderFace(at: point.location) }
                return
            }
            nodesMoved(to: last.location)
        case .transform:
            transformMoved(to: last.location)
        case .shape:
            draftShape?.end = last.location
        case .gradient:
            draftGradient?.end = last.location
        case .crop:
            if draftStraighten != nil {
                draftStraighten?.end = last.location
            } else if let drag = quadDrag {
                let canvas = read().canvasRect
                perspectiveQuad?[drag.corner] = CGPoint(
                    x: min(max(drag.origin.x + last.location.x - drag.start.x, canvas.minX), canvas.maxX),
                    y: min(max(drag.origin.y + last.location.y - drag.start.y, canvas.minY), canvas.maxY)
                )
            } else {
                continueCropDrag(to: last.location)
            }
        case .eyedropper:
            sampleColor(at: last.location)
        case .fill, .text:
            break
        }
    }

    /// The finger lifted. `isTap` when it barely moved.
    func toolEnded(isTap: Bool, at point: CGPoint) {
        if isSmudging {
            if let blocker = paintingBlocker(), isTap {
                errorMessage = blocker
                return
            }
            finishSmudge()
            return
        }
        switch tool {
        case .liquify:
            if let blocker = paintingBlocker(), isTap {
                errorMessage = blocker
                return
            }
            finishSmudge()
        case .brush, .eraser, .censor, .tone, .heal, .clone:
            dockedEdge = nil
            if let blocker = paintingBlocker(), isTap {
                errorMessage = blocker
                return
            }
            if tool == .clone, cloneSource == nil || isPickingCloneSource {
                pickCloneSource(at: point)
                return
            }
            guard let stroke = activeStroke, let layerID = activeLayerID else { return }
            activeStroke = nil
            if case .clone(let offset) = stroke.kind, let last = stroke.points.last?.location {
                cloneSource = CGPoint(x: last.x + offset.dx, y: last.y + offset.dy)
            }
            if editsAnyMask {
                commitMask(stroke, to: layerID, filters: editsFilterMask)
            } else {
                commit(stroke, to: layerID)
            }
        case .move:
            if let guide = draggedGuide {
                draggedGuide = nil
                dropGuide(guide)
                return
            }
            moveOrigin = nil
            groupMoveOrigin = nil
            snapLines = []
            if isTap { selectLayer(at: point) }
        case .select:
            defer { draftSelection = nil }
            if !selectionKind.isDrawn {
                guard isTap else { return }
                if selectionKind == .object { selectObject(at: point) } else { magicSelect(at: point) }
            } else if isTap {
                if selectionMode == .replace { selection = nil }
            } else if let draft = draftSelection, draft.isMeaningful {
                select(draft)
            }
        case .pen:
            vectorDrag = nil
            vectorDragOrigin = nil
        case .nodes:
            guard shapeBuilder == nil else { return }
            nodesEnded(isTap: isTap, at: point)
        case .transform:
            transformEnded()
        case .shape:
            defer { draftShape = nil }
            guard let spec = draftShape, spec.isMeaningful else { return }
            addShapeLayer(spec)
        case .gradient:
            defer { draftGradient = nil }
            if isTap, let blocker = paintingBlocker() {
                errorMessage = blocker
                return
            }
            guard let draft = draftGradient, hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 2 else {
                return
            }
            applyGradient(from: draft.start, to: draft.end)
        case .crop:
            cropDrag = nil
            quadDrag = nil
            if let line = draftStraighten {
                draftStraighten = nil
                guard hypot(line.end.x - line.start.x, line.end.y - line.start.y) > 4 else { return }
                straighten(by: Composition.straighteningAngle(from: line.start, to: line.end))
            }
        case .fill:
            guard isTap else { return }
            floodFill(at: point)
        case .text:
            guard isTap else { return }
            placeText(at: point)
        case .eyedropper:
            break
        }
    }

    /// A second finger came down, or the system took the touch: nothing the
    /// gesture had started is kept.
    func toolCancelled() {
        activeStroke = nil
        dockedEdge = nil
        smudge = nil
        draftSelection = nil
        draftShape = nil
        draftGradient = nil
        cropDrag = nil
        draftStraighten = nil
        snapLines = []
        draggedGuide = nil
        if let drag = transformDrag, var draft = transformDraft {
            for handle in drag.handles { draft.points[handle.index] = handle.origin }
            transformDraft = draft
            transformDrag = nil
            updateTransformPreview()
        }
        if let origin = moveOrigin {
            update { $0[origin.layerID]?.transform = origin.transform }
            moveOrigin = nil
        }
        if let group = groupMoveOrigin {
            update { composition in
                for (id, transform) in group.layers { composition[id]?.transform = transform }
            }
            groupMoveOrigin = nil
        }
        if vectorDrag != nil, let origin = vectorDragOrigin {
            update { $0[origin.id] = origin }
        }
        vectorDrag = nil
        vectorDragOrigin = nil
    }

    private func shape(for kind: SelectionKind, from start: CGPoint, to end: CGPoint) -> Selection.Shape {
        let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
        switch kind {
        case .rectangle: return .rectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .lasso, .magnetic, .magic, .object: return .lasso([start])
        }
    }

    // MARK: - Magnetic select

    /// Works out the picture's edges, unless they are already known for it.
    private func prepareEdgeMap() {
        let composition = composition
        guard edgeMapSource != composition else { return }
        edgeMapSource = composition
        edgeMap = nil
        Task { @MainActor in
            let map = await Task.detached(priority: .userInitiated) { EdgeMap(composition: composition) }.value
            if edgeMapSource == composition { edgeMap = map }
        }
    }

    /// The finger's path pulled onto the nearest strong edge, with points
    /// too close together left out so the outline stays smooth.
    private func magneticPoints(_ points: [CGPoint], after previous: CGPoint?) -> [CGPoint] {
        guard let edgeMap else { return points }
        // About a fingertip's reach on screen.
        let radius = max(4, 16 / max(viewport.scale, 0.0001))
        var result: [CGPoint] = []
        var last = previous
        for point in points {
            let snapped = edgeMap.snap(point, radius: radius)
            if let last, hypot(snapped.x - last.x, snapped.y - last.y) < edgeMap.scale { continue }
            result.append(snapped)
            last = snapped
        }
        return result
    }

    // MARK: - Simple tool actions

    func sampleColor(at point: CGPoint) {
        guard let sampled = CompositionRenderer.color(at: point, in: read()) else { return }
        color = sampled
    }

    /// Picks the topmost visible layer under the point, the way tapping an
    /// object picks it.
    func selectLayer(at point: CGPoint) {
        let composition = read()
        if let hit = composition.layers.last(where: { $0.isVisible && $0.contains(point) }) {
            activeLayerID = hit.id
        }
    }

    // MARK: - Crop

    private func beginCropDrag(at point: CGPoint) {
        guard let rect = cropRect else { return }
        // Grab an edge from this far away, in canvas pixels.
        let reach = 28 / max(viewport.scale, 0.0001)
        func edge(_ value: CGFloat, _ min: CGFloat, _ max: CGFloat) -> Int {
            if abs(value - min) < reach { return -1 }
            if abs(value - max) < reach { return 1 }
            return 0
        }
        cropDrag = CropDrag(
            horizontal: edge(point.x, rect.minX, rect.maxX), vertical: edge(point.y, rect.minY, rect.maxY),
            start: point, rect: rect
        )
    }

    private func continueCropDrag(to point: CGPoint) {
        guard let drag = cropDrag else { return }
        let canvas = read().canvasRect
        let dx = point.x - drag.start.x
        let dy = point.y - drag.start.y
        var rect = drag.rect
        if drag.horizontal == 0 && drag.vertical == 0 {
            // Inside: the frame moves, kept on the canvas.
            rect.origin.x = min(max(rect.minX + dx, 0), canvas.width - rect.width)
            rect.origin.y = min(max(rect.minY + dy, 0), canvas.height - rect.height)
            cropRect = rect
            return
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let minimum: CGFloat = 16
        if drag.horizontal < 0 { minX = min(max(0, minX + dx), maxX - minimum) }
        if drag.horizontal > 0 { maxX = max(min(canvas.width, maxX + dx), minX + minimum) }
        if drag.vertical < 0 { minY = min(max(0, minY + dy), maxY - minimum) }
        if drag.vertical > 0 { maxY = max(min(canvas.height, maxY + dy), minY + minimum) }
        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = cropAspect.ratio(for: canvas.size) {
            rect = Self.fit(rect, to: ratio, anchoredOpposite: drag, in: canvas)
        }
        cropRect = rect
    }

    /// Bends a dragged frame to a fixed shape, keeping the corner or edge
    /// opposite the one being dragged where it was.
    private static func fit(_ rect: CGRect, to ratio: Double, anchoredOpposite drag: CropDrag, in canvas: CGRect) -> CGRect {
        var width = rect.width
        var height = rect.height
        if drag.vertical == 0 || (drag.horizontal != 0 && width / height > ratio) {
            height = width / ratio
        } else {
            width = height * ratio
        }
        let anchorX = drag.horizontal < 0 ? rect.maxX : rect.minX
        let anchorY = drag.vertical < 0 ? rect.maxY : rect.minY
        var result = CGRect(
            x: drag.horizontal < 0 ? anchorX - width : anchorX,
            y: drag.vertical < 0 ? anchorY - height : anchorY,
            width: width, height: height
        )
        if !canvas.contains(result) {
            let clipped = result.intersection(canvas)
            let scale = min(clipped.width / result.width, clipped.height / result.height)
            result.size = CGSize(width: result.width * scale, height: result.height * scale)
            result.origin.x = drag.horizontal < 0 ? anchorX - result.width : anchorX
            result.origin.y = drag.vertical < 0 ? anchorY - result.height : anchorY
        }
        return result
    }

    /// Fits the crop frame to the chosen proportions, centred where it was.
    func constrainCropRect() {
        guard let rect = cropRect else { return }
        let canvas = read().canvasRect
        guard let ratio = cropAspect.ratio(for: canvas.size) else { return }
        var size = rect.size
        if size.width / size.height > ratio {
            size.width = size.height * ratio
        } else {
            size.height = size.width / ratio
        }
        cropRect = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            .intersection(canvas)
    }

    func applyCrop() {
        if cropMode == .perspective, let quad = perspectiveQuad {
            applyPerspectiveCrop(quad)
            return
        }
        guard let rect = cropRect?.integral else { return }
        let canvas = read().canvasRect
        guard rect != canvas else { return }
        let before = (read(), selection)
        update { $0.crop(to: rect) }
        selection = selection.map {
            $0.applying(CGAffineTransform(translationX: -rect.minX, y: -rect.minY), canvasSize: rect.size)
        }
        noteCanvasChange(from: before.0, selection: before.1)
        cropRect = read().canvasRect
        cropAspect = .free
        fitCanvas()
    }

    /// Turns the picture and crops off the corners the turn leaves empty.
    func straighten(by angle: Double) {
        guard abs(angle) > 0.0001 else { return }
        let before = (read(), selection)
        update { $0.straighten(by: angle) }
        selection = nil
        noteCanvasChange(from: before.0, selection: before.1)
        cropRect = read().canvasRect
        cropAspect = .free
        cropMode = .frame
        fitCanvas()
    }

    /// Flattens what lies within `quad` square-on, off the main thread.
    func applyPerspectiveCrop(_ quad: [CGPoint]) {
        let composition = read()
        enqueue({ () -> Composition? in
            var cropped = composition
            cropped.perspectiveCrop(to: quad)
            return cropped.size == composition.size && cropped.layers == composition.layers ? nil : cropped
        }, apply: { [weak self] cropped in
            guard let self else { return }
            let before = (read(), selection)
            self.write(cropped)
            self.selection = nil
            noteCanvasChange(from: before.0, selection: before.1)
            self.cropMode = .frame
            self.cropRect = cropped.canvasRect
            self.fitCanvas()
        })
    }

    /// Where a perspective crop's corners start: a little in from the
    /// canvas's own.
    static func startingQuad(in canvas: CGRect) -> [CGPoint] {
        let inset = canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
        return [
            CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
            CGPoint(x: inset.maxX, y: inset.maxY), CGPoint(x: inset.minX, y: inset.maxY),
        ]
    }

    func resetCrop() {
        if cropMode == .perspective { perspectiveQuad = Self.startingQuad(in: read().canvasRect) }
        cropAspect = .free
        cropRect = read().canvasRect
    }

    // MARK: - Work off the main thread

    /// Runs `work` off the main thread, after every edit queued before it,
    /// and hands its result to `apply` back on the main thread.
    func enqueue<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result?,
        apply: @escaping @MainActor (Result) -> Void,
        finally: @escaping @MainActor () -> Void = {}
    ) {
        let previous = queue
        runningJobs += 1
        queue = Task { @MainActor in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { work() }.value
            if let result { apply(result) }
            finally()
            runningJobs -= 1
        }
    }

    /// Replaces a layer's pixels with ones worked out from it, after making
    /// its pixels line up with the canvas. The layer is read when the work
    /// starts, so queued edits build on each other. Its filters stay.
    func editPixels(
        of layerID: Layer.ID, mask: Bool = false, finally: @escaping @MainActor () -> Void = {},
        _ edit: @escaping @Sendable (CGImage, CGSize) -> CGImage?
    ) {
        let previous = queue
        runningJobs += 1
        queue = Task { @MainActor in
            await previous?.value
            let composition = read()
            if let layer = composition[layerID] {
                let size = composition.size
                let result = await Task.detached(priority: .userInitiated) { () -> Layer? in
                    let aligned = layer.aligned(in: size)
                    var edited = aligned
                    if mask {
                        guard let target = aligned.mask, let image = edit(target.image.cgImage, size) else { return nil }
                        edited.mask?.image = LayerImage(image)
                    } else {
                        guard let image = edit(aligned.image.cgImage, size) else { return nil }
                        edited.image = LayerImage(image)
                    }
                    return edited
                }.value
                if let result {
                    // Whatever happened to the layer meanwhile besides its
                    // pixels — a rename, a new opacity, a move — is kept.
                    update { composition in
                        guard var current = composition[layerID] else { return }
                        if current.transform == layer.transform {
                            current.transform = result.transform
                        } else if result.transform != layer.transform {
                            // Moved while the edit was worked out, from
                            // pixels lined up anew: they follow the move.
                            current.transform = Self.placement(of: result, carriedFrom: layer, to: current)
                        }
                        current.image = result.image
                        current.text = nil
                        current.vector = nil
                        // Its pixels are no longer drawn from its contents.
                        current.smartObject = nil
                        if let mask = result.mask { current.mask?.image = mask.image }
                        if let mask = result.filterMask { current.filterMask?.image = mask.image }
                        composition[layerID] = current
                    }
                }
            }
            finally()
            runningJobs -= 1
        }
    }

    /// Where `edited` — worked out from `original` — goes when the layer has
    /// since been moved, turned or scaled to where `moved` is: carried by
    /// that same change. A skew, which a placement cannot hold, is dropped.
    nonisolated static func placement(of edited: Layer, carriedFrom original: Layer, to moved: Layer) -> LayerTransform {
        let change = original.affineTransform.inverted().concatenating(moved.affineTransform)
        let size = edited.image.size
        // The placement without its last step, moving the centre to the origin.
        let placed = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .concatenating(edited.affineTransform)
            .concatenating(change)
        let scaleX = hypot(placed.a, placed.b)
        guard scaleX > 0 else { return edited.transform }
        return LayerTransform(
            position: CGPoint(x: placed.tx, y: placed.ty), scaleX: scaleX,
            scaleY: (placed.a * placed.d - placed.b * placed.c) / scaleX, rotation: atan2(placed.b, placed.a)
        )
    }

    /// Hides or reveals parts of a layer's mask where `coverage` — drawn on
    /// a canvas-sized image — is opaque. The mask is changed where the layer
    /// sits, however it is moved or turned, so text, vector and smart object
    /// layers stay what they are.
    /// `filters` edits the filter mask instead.
    func editMask(
        of layerID: Layer.ID, hides: Bool, filters: Bool = false, finally: @escaping @MainActor () -> Void = {},
        coverage: @escaping @Sendable (CGSize) -> CGImage?
    ) {
        let target: WritableKeyPath<Layer, LayerMask?> = filters ? \.filterMask : \.mask
        let previous = queue
        runningJobs += 1
        queue = Task { @MainActor in
            await previous?.value
            let composition = read()
            if let layer = composition[layerID], let mask = layer[keyPath: target] {
                let size = composition.size
                let result = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let painted = coverage(size) else { return nil }
                    return Painter.apply(coverage: painted, toMask: mask.image.cgImage, of: layer, hides: hides)
                }.value
                if let result {
                    update { composition in
                        guard var current = composition[layerID], current[keyPath: target] != nil else { return }
                        current[keyPath: target]?.image = LayerImage(result)
                        composition[layerID] = current
                    }
                }
            }
            finally()
            runningJobs -= 1
        }
    }

    /// The stroke and, with symmetry on, its mirror images. Only the brush
    /// and eraser paint mirrored.
    func mirrored(_ stroke: Stroke) -> [Stroke] {
        guard stroke.kind.isPaint else { return [stroke] }
        return symmetry.strokes(for: stroke, in: composition.size)
    }

    private func commitMask(_ stroke: Stroke, to layerID: Layer.ID, filters: Bool) {
        let strokes = mirrored(stroke)
        let pending = strokes.map { PendingStroke(layerID: layerID, stroke: $0, isMask: !filters, isFilterMask: filters) }
        pendingStrokes.append(contentsOf: pending)
        let ids = Set(pending.map(\.id))
        // The brush hides and the eraser reveals; mirrored copies alike.
        let hides = stroke.kind == .erase
        editMask(of: layerID, hides: hides, filters: filters, finally: { [weak self] in
            self?.pendingStrokes.removeAll { ids.contains($0.id) }
        }) { size in
            Bitmap.render(size: size) { context in
                for var stroke in strokes {
                    stroke.kind = .paint
                    stroke.settings.color = .white
                    stroke.paint(in: context, canvasSize: size)
                }
            }
        }
    }

    private func commit(_ stroke: Stroke, to layerID: Layer.ID) {
        if stroke.kind.isPaint, symmetry != .off {
            // Every copy in one edit, so one undo takes the whole stroke.
            let strokes = mirrored(stroke)
            let pending = strokes.map { PendingStroke(layerID: layerID, stroke: $0) }
            pendingStrokes.append(contentsOf: pending)
            let ids = Set(pending.map(\.id))
            editPixels(of: layerID, finally: { [weak self] in
                self?.pendingStrokes.removeAll { ids.contains($0.id) }
            }) { image, _ in
                strokes.reduce(image) { Painter.paint($1, onto: $0) }
            }
            return
        }
        let pending = PendingStroke(layerID: layerID, stroke: stroke)
        pendingStrokes.append(pending)
        // The blurred or tiled layer worked out for showing the stroke, if
        // it is still for these pixels; otherwise it is made again.
        let prepared = retouchEffect
        editPixels(of: layerID, finally: { [weak self] in
            self?.pendingStrokes.removeAll { $0.id == pending.id }
        }) { image, _ in
            switch stroke.kind {
            case .paint, .erase:
                return Painter.paint(stroke, onto: image)
            case .blur, .mosaic, .motionBlur, .clone, .tone:
                let effect = prepared.flatMap { $0.matches(stroke, source: image) ? $0.image : nil }
                    ?? RetouchEffect.image(stroke.kind, settings: stroke.settings, of: image)
                return Painter.apply(effect, onto: image, through: stroke)
            case .heal:
                return Healer.heal(image, with: stroke)
            }
        }
    }

    private func floodFill(at point: CGPoint) {
        if let blocker = paintingBlocker() {
            errorMessage = blocker
            return
        }
        guard let layerID = activeLayerID else { return }
        let color = color
        let tolerance = fillTolerance
        let selection = selection
        if fillsWithPattern {
            let pattern = currentFillPattern
            let swatches = composition.patterns
            editPixels(of: layerID) { image, size in
                Painter.floodFill(image, at: point, with: pattern, swatches: swatches, tolerance: tolerance, clip: selection)
            }
            return
        }
        editPixels(of: layerID) { image, size in
            Painter.floodFill(image, at: point, with: color, tolerance: tolerance, clip: selection)
        }
    }

    private func applyGradient(from start: CGPoint, to end: CGPoint) {
        guard let layerID = activeLayerID else { return }
        // On a mask, a gradient fades the layer out from where it starts.
        let onMask = editsAnyMask
        let onFilterMask = editsFilterMask
        let gradient = onMask
            ? PaintGradient.fading(.white, kind: gradientKind)
            : PaintGradient(kind: gradientKind, stops: gradientStopsShown)
        let opacity = gradientOpacity
        let selection = selection
        if onMask {
            editMask(of: layerID, hides: true, filters: onFilterMask) { size in
                Painter.gradient(
                    gradient, from: start, to: end, opacity: opacity, clip: selection,
                    onto: Bitmap.solid(size: size, color: .clear)
                )
            }
            return
        }
        editPixels(of: layerID) { image, size in
            Painter.gradient(gradient, from: start, to: end, opacity: opacity, clip: selection, onto: image)
        }
    }
}

/// The mapping between canvas pixels and the points of the view showing them.
struct CanvasViewport: Equatable {
    var canvasSize: CGSize
    var viewportSize: CGSize
    var insets: EdgeInsets
    var zoom: Double
    var pan: CGSize
    /// Radians clockwise, about the middle of the view.
    var rotation: Double = 0

    /// The scale at which the canvas just fits the clear area.
    var fitScale: Double {
        let width = viewportSize.width - insets.leading - insets.trailing - 32
        let height = viewportSize.height - insets.top - insets.bottom - 32
        guard canvasSize.width > 0, canvasSize.height > 0, width > 0, height > 0 else { return 1 }
        return min(width / canvasSize.width, height / canvasSize.height)
    }

    /// Points per canvas pixel.
    var scale: Double { fitScale * zoom }

    /// The middle of the clear area, where a fitted canvas is centred.
    private var restingCenter: CGPoint {
        CGPoint(
            x: insets.leading + (viewportSize.width - insets.leading - insets.trailing) / 2,
            y: insets.top + (viewportSize.height - insets.top - insets.bottom) / 2
        )
    }

    /// Where the canvas sits before the view is turned.
    var canvasFrame: CGRect {
        let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: restingCenter.x + pan.width - size.width / 2,
            y: restingCenter.y + pan.height - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// The middle of the view, which the view turns about.
    var center: CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    /// Canvas pixels to view points.
    var transform: CGAffineTransform {
        let frame = canvasFrame
        let level = CGAffineTransform(translationX: frame.minX, y: frame.minY).scaledBy(x: scale, y: scale)
        guard rotation != 0 else { return level }
        let center = center
        return level
            .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// The view before it is turned, on a square wide enough that, turned
    /// about the view's middle, it still covers every corner of the view.
    /// Centred on the view and turned by `rotation`, it shows what this
    /// viewport does.
    var level: CanvasViewport {
        guard rotation != 0 else { return self }
        let side = hypot(viewportSize.width, viewportSize.height).rounded(.up)
        let marginX = (side - viewportSize.width) / 2
        let marginY = (side - viewportSize.height) / 2
        var level = self
        level.rotation = 0
        level.viewportSize = CGSize(width: side, height: side)
        level.insets = EdgeInsets(
            top: insets.top + marginY, leading: insets.leading + marginX,
            bottom: insets.bottom + marginY, trailing: insets.trailing + marginX
        )
        return level
    }

    func screenPoint(_ canvasPoint: CGPoint) -> CGPoint {
        canvasPoint.applying(transform)
    }

    func canvasPoint(_ screenPoint: CGPoint) -> CGPoint {
        screenPoint.applying(transform.inverted())
    }
}
