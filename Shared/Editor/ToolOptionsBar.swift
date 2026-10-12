import PhotosUI
import SwiftUI

/// The settings of the tool in hand, in a glass bar over the canvas: above
/// the carousel on iPhone, along the bottom on iPad.
struct ToolOptionsBar: View {
    @Bindable var state: EditorState

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                options
            }
            .padding(.horizontal, 12)
            .animation(.snappy(duration: 0.2), value: state.tool)
        }
        .frame(height: EditorToolbarMetrics.rowHeight)
    }

    @ViewBuilder
    private var options: some View {
        switch state.tool {
        case .brush, .eraser, .liquify, .heal: brushOptions
        case .censor:
            censorOptions
            brushOptions
        case .tone:
            toneOptions
            brushOptions
        case .clone:
            brushOptions
            cloneOptions
        case .fill: fillOptions
        case .gradient: gradientOptions
        case .eyedropper: eyedropperOptions
        case .move: moveOptions
        case .select: selectOptions
        case .crop: cropOptions
        case .transform: transformOptions
        case .text: textOptions
        case .shape: shapeOptions
        case .pen: penOptions
        case .nodes: nodeOptions
        }
    }

    private var toneOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            GlassMenuButton(symbol: state.toneKind.symbolName, label: "Tone.Type") {
                Picker("Tone.Type", selection: $state.toneKind) {
                    ForEach(ToneKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                            .accessibilityIdentifier("tone.type.\(kind.rawValue)")
                    }
                }
            }
            .accessibilityIdentifier("tone.type")
        }
    }

    private var censorOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            GlassMenuButton(symbol: state.censorKind.symbolName, label: "Censor.Type") {
                Picker("Censor.Type", selection: $state.censorKind) {
                    ForEach(CensorKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                            .accessibilityIdentifier("censor.type.\(kind.rawValue)")
                    }
                }
            }
            .accessibilityIdentifier("censor.type")
            if state.censorKind == .motionBlur {
                OptionSlider(
                    value: $state.censorAngle, range: 0...180,
                    label: "LayerFilters.Angle", valueText: "\(Int(state.censorAngle.rounded()))°"
                )
                .accessibilityIdentifier("censor.angle")
            }
        }
    }

    // MARK: - Painting

    private var brushOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            if state.tool == .brush { ColorWell(state: state) }
            OptionSlider(
                value: Binding(
                    get: { BrushSizeScale.position(for: state.currentBrush.size) },
                    set: { state.currentBrush.size = BrushSizeScale.size(at: $0) }
                ),
                label: "Options.Size", valueText: "\(Int(state.currentBrush.size.rounded())) px"
            )
            .accessibilityIdentifier("brushSize")
            BrushSettingsButton(state: state)
            if state.tool == .brush || state.tool == .eraser {
                GlassMenuButton(symbol: state.symmetry.symbolName, label: "Symmetry.Title") {
                    Picker("Symmetry.Title", selection: $state.symmetry) {
                        ForEach(Symmetry.allCases) { symmetry in
                            Label(symmetry.label, systemImage: symmetry.symbolName).tag(symmetry)
                        }
                    }
                }
                .accessibilityIdentifier("symmetry")
            }
            if state.tool.usesStrokes && !state.isSmudging {
                GlassIconButton(symbol: "ruler", label: "Ruler.Title", isOn: state.ruler != nil) {
                    state.toggleRuler()
                }
                .accessibilityIdentifier("ruler.toggle")
            }
        }
    }

    /// Lit while the next tap picks where to copy from, which is also the
    /// case until a source has been picked.
    private var cloneOptions: some View {
        GlassIconButton(
            symbol: "dot.scope", label: "Options.CloneSource",
            isOn: state.isPickingCloneSource || state.cloneSource == nil
        ) {
            state.isPickingCloneSource.toggle()
        }
        .accessibilityIdentifier("cloneSource")
    }

    private var fillOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            ColorWell(state: state)
            OptionSlider(
                value: $state.fillTolerance, label: "Options.Tolerance",
                valueText: "\(Int((state.fillTolerance * 100).rounded()))%"
            )
        }
    }

    private var gradientOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            GlassMenuButton(symbol: state.gradientKind.symbolName, label: "Gradient.Kind") {
                Picker("Gradient.Kind", selection: $state.gradientKind) {
                    ForEach(PaintGradient.Kind.allCases) { kind in
                        Label(LocalizedStringKey(kind.labelKey), systemImage: kind.symbolName).tag(kind)
                            .accessibilityIdentifier("gradientKind.\(kind.rawValue)")
                    }
                }
            }
            .accessibilityIdentifier("gradientKind")
            ColorWell(state: state)
            GradientWell(stops: state.gradientStopsBinding, choosePreset: state.applyGradientPreset)
            OptionSlider(
                value: $state.gradientOpacity, label: "Options.Opacity",
                valueText: "\(Int((state.gradientOpacity * 100).rounded()))%"
            )
        }
    }

    private var eyedropperOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            ColorWell(state: state)
            Text(state.color.hexString)
                .font(.system(size: 15, weight: .medium).monospaced())
                .padding(.trailing, 12)
                .accessibilityIdentifier("sampledColor")
        }
    }

    // MARK: - Arranging

    private var moveOptions: some View {
        let isLocked = state.activeLayer?.isLocked ?? true
        return Group {
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Options.FlipHorizontal") {
                    state.updateTransform { $0.scaleX = -$0.scaleX; $0.rotation = -$0.rotation }
                }
                GlassIconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Options.FlipVertical") {
                    state.updateTransform { $0.scaleY = -$0.scaleY; $0.rotation = -$0.rotation }
                }
                GlassIconButton(symbol: "rotate.right", label: "Options.RotateLayer") {
                    state.updateTransform { $0.rotation = Self.normalized($0.rotation + .pi / 2) }
                }
                TransformSettingsButton(state: state)
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Options.FitToCanvas") {
                    state.fitLayerToCanvas()
                }
                GlassIconButton(symbol: "arrow.counterclockwise", label: "Options.ResetTransform") {
                    state.resetTransform()
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "squareshape.dotted.split.2x2", label: "Options.Snap", isOn: state.snaps) {
                    state.snaps.toggle()
                }
                .accessibilityIdentifier("snap")
            }
        }
        .disabled(isLocked)
    }

    /// An angle brought back into -π...π.
    static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }

    private var selectOptions: some View {
        Group {
            GlassGroup(scrollsHorizontally: true) {
                GlassMenuButton(symbol: state.selectionMode.symbolName, label: "Select.Mode") {
                    Picker("Select.Mode", selection: $state.selectionMode) {
                        ForEach(SelectionMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbolName).tag(mode)
                                .accessibilityIdentifier("selectionMode.\(mode.rawValue)")
                        }
                    }
                }
                .accessibilityIdentifier("selectionMode")
            }
            GlassGroup(scrollsHorizontally: true) {
                ForEach(SelectionKind.allCases) { kind in
                    GlassIconButton(symbol: kind.symbolName, label: kind.label, isOn: state.selectionKind == kind) {
                        state.selectionKind = kind
                    }
                    .accessibilityIdentifier("selectionKind.\(kind.rawValue)")
                }
            }
            if state.selectionKind == .magic {
                GlassGroup(scrollsHorizontally: true) {
                    OptionSlider(
                        value: $state.selectionTolerance, label: "Options.Tolerance",
                        valueText: "\(Int((state.selectionTolerance * 100).rounded()))%"
                    )
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                SelectionMenu(state: state)
            }
        }
    }

    private var cropOptions: some View {
        Group {
            GlassGroup(scrollsHorizontally: true) {
                ForEach(CropMode.allCases) { mode in
                    GlassIconButton(symbol: mode.symbolName, label: mode.label, isOn: state.cropMode == mode) {
                        state.cropMode = mode
                    }
                    .accessibilityIdentifier("cropMode.\(mode.rawValue)")
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassMenuButton(symbol: "aspectratio", label: "Options.AspectRatio") {
                    Picker("Options.AspectRatio", selection: $state.cropAspect) {
                        ForEach(CropAspect.allCases) { aspect in
                            Text(aspect.label).tag(aspect)
                        }
                    }
                }
                GlassIconButton(symbol: "rotate.left", label: "Canvas.RotateLeft") {
                    state.rotateCanvas(clockwise: false)
                }
                GlassIconButton(symbol: "rotate.right", label: "Canvas.RotateRight") {
                    state.rotateCanvas(clockwise: true)
                }
                GlassIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Canvas.FlipHorizontal") {
                    state.flipCanvas(horizontal: true)
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "xmark", label: "Options.CropReset") {
                    state.resetCrop()
                }
                GlassIconButton(symbol: "checkmark", label: "Options.CropApply", isOn: true) {
                    state.applyCrop()
                }
                .disabled(state.cropRect?.integral == state.composition.canvasRect)
                .accessibilityIdentifier("applyCrop")
            }
        }
    }

    private var transformOptions: some View {
        let draft = state.transformDraft
        return Group {
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "perspective", label: "Transform.Distort", isOn: state.transformMode == .distort) {
                    state.setTransformMode(.distort)
                }
                GlassIconButton(symbol: "squareshape.split.3x3", label: "Transform.Warp", isOn: state.transformMode == .warp) {
                    state.setTransformMode(.warp)
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(symbol: "xmark", label: "Transform.Reset") {
                    state.resetTransformDraft()
                }
                GlassIconButton(symbol: "checkmark", label: "Transform.Apply", isOn: true) {
                    state.applyTransform()
                }
                .accessibilityIdentifier("applyTransform")
            }
            .disabled(!(draft?.isChanged ?? false))
        }
        .disabled(state.activeLayer.map { state.composition.isLocked($0) } ?? true)
    }

    // MARK: - Adding

    private var textOptions: some View {
        GlassGroup(scrollsHorizontally: true) {
            ColorWell(state: state)
            if state.activeLayer?.isText == true {
                Button("Options.EditText") { state.presentedPanel = .text }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: EditorToolbarMetrics.controlSize)
                    .buttonStyle(.plain)
            } else {
                Text("Options.TapToAddText")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var penOptions: some View {
        Group {
            GlassGroup(scrollsHorizontally: true) {
                ColorWell(state: state)
                GlassIconButton(
                    symbol: state.shapeIsFilled ? "square.fill" : "square", label: "Options.ShapeFilled",
                    isOn: state.shapeIsFilled
                ) {
                    state.shapeIsFilled.toggle()
                }
                OptionSlider(
                    value: Binding(
                        get: { BrushSizeScale.position(for: state.shapeLineWidth) },
                        set: { state.shapeLineWidth = BrushSizeScale.size(at: $0) }
                    ),
                    label: "Options.LineWidth", valueText: "\(Int(state.shapeLineWidth.rounded())) px"
                )
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(
                    symbol: state.penAddsToLayer ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                    label: "Options.PenAddsToLayer", isOn: state.penAddsToLayer
                ) {
                    state.penAddsToLayer.toggle()
                }
                .accessibilityIdentifier("penAddsToLayer")
            }
            if state.penPath != nil {
                GlassGroup(scrollsHorizontally: true) {
                    GlassIconButton(symbol: "checkmark", label: "Options.FinishPath", isOn: true) {
                        state.finishPath()
                    }
                    .accessibilityIdentifier("finishPath")
                }
            } else {
                Text("Options.TapToStartPath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var nodeOptions: some View {
        if state.styledVectorPath != nil {
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(
                    symbol: "checklist", label: "Options.SelectMultiplePoints", isOn: state.isSelectingMultiplePoints
                ) {
                    state.isSelectingMultiplePoints.toggle()
                }
                .accessibilityIdentifier("selectMultiplePoints")
                GlassIconButton(symbol: "circle.grid.3x3.fill", label: "Options.SelectAllPoints") {
                    state.selectAllPoints()
                }
            }
        }
        if let path = state.styledVectorPath {
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(
                    symbol: path.fill == nil ? "square" : "square.fill", label: "Options.Fill", isOn: path.fill != nil
                ) {
                    state.updateVectorStyle { $0.fill = $0.fill == nil ? state.color : nil }
                }
                .accessibilityIdentifier("vectorFill")
                if let fill = path.fill {
                    if let gradient = path.fillGradient {
                        GlassMenuButton(symbol: gradient.kind.symbolName, label: "Gradient.Kind") {
                            Picker("Gradient.Kind", selection: Binding(
                                get: { gradient.kind },
                                set: { kind in state.updateVectorStyle { $0.fillGradient?.kind = kind } }
                            )) {
                                ForEach(PaintGradient.Kind.allCases) { kind in
                                    Label(LocalizedStringKey(kind.labelKey), systemImage: kind.symbolName).tag(kind)
                                }
                            }
                        }
                        GradientWell(
                            stops: Binding(
                                get: { gradient.stops },
                                set: { stops in state.updateVectorStyle { $0.fillGradient?.stops = stops } }
                            ),
                            choosePreset: { preset in
                                state.updateVectorStyle { $0.fillGradient?.stops = preset.stops(with: state.color) }
                            }
                        )
                        OptionSlider(
                            value: Binding(
                                get: { path.gradientAngle ?? 0 },
                                set: { value in state.updateVectorStyle { $0.gradientAngle = value } }
                            ),
                            range: -180...180, label: "LayerFilters.Angle",
                            valueText: "\(Int((path.gradientAngle ?? 0).rounded()))°"
                        )
                    } else {
                        VectorColorWell(color: fill) { color in state.updateVectorStyle { $0.fill = color } }
                    }
                    GlassIconButton(
                        symbol: "circle.lefthalf.striped.horizontal", label: "Options.GradientFill",
                        isOn: path.fillGradient != nil
                    ) {
                        state.updateVectorStyle { path in
                            path.fillGradient = path.fillGradient == nil
                                ? PaintGradient(kind: state.gradientKind, stops: state.gradientStopsShown) : nil
                        }
                    }
                    .accessibilityIdentifier("vectorGradientFill")
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                GlassIconButton(
                    symbol: "scribble", label: "Options.Stroke", isOn: path.stroke != nil
                ) {
                    state.updateVectorStyle { $0.stroke = $0.stroke == nil ? state.color : nil }
                }
                .accessibilityIdentifier("vectorStroke")
                if let stroke = path.stroke {
                    VectorColorWell(color: stroke) { color in state.updateVectorStyle { $0.stroke = color } }
                    OptionSlider(
                        value: Binding(
                            get: { BrushSizeScale.position(for: path.strokeWidth) },
                            set: { value in state.updateVectorStyle { $0.strokeWidth = BrushSizeScale.size(at: value) } }
                        ),
                        label: "Options.LineWidth", valueText: "\(Int(path.strokeWidth.rounded())) px"
                    )
                }
            }
            if state.canCombineShapes {
                GlassGroup(scrollsHorizontally: true) {
                    GlassMenuButton(symbol: "square.on.square.squareshape.controlhandles", label: "Vector.Combine") {
                        ForEach(VectorBoolean.allCases) { operation in
                            Button {
                                state.combineShapes(operation)
                            } label: {
                                Label {
                                    Text(verbatim: operation.label)
                                } icon: {
                                    Image(systemName: operation.symbolName)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("combineShapes")
                }
            }
            if let node = state.selectedVectorNode {
                GlassGroup(scrollsHorizontally: true) {
                    GlassIconButton(
                        symbol: node.isSmooth ? "point.topleft.down.curvedto.point.bottomright.up" : "chevron.up",
                        label: node.isSmooth ? "Options.MakeCorner" : "Options.MakeSmooth"
                    ) {
                        state.toggleSmooth()
                    }
                    GlassIconButton(symbol: "plus.circle", label: "Options.AddPoint") {
                        state.insertNodeAfterSelected()
                    }
                    GlassIconButton(symbol: "minus.circle", label: "Options.DeletePoint") {
                        state.deleteSelectedNode()
                    }
                    .accessibilityIdentifier("deletePoint")
                    PathTextButton(state: state)
                    GlassIconButton(
                        symbol: state.selectedVectorPath?.isClosed == true ? "circle.dashed" : "circle",
                        label: state.selectedVectorPath?.isClosed == true ? "Options.OpenPath" : "Options.ClosePath"
                    ) {
                        state.toggleClosed()
                    }
                }
            }
        } else {
            Text("Options.PickVectorLayer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }

    private var shapeOptions: some View {
        Group {
            GlassGroup(scrollsHorizontally: true) {
                ForEach(ShapeSpec.Kind.allCases) { kind in
                    GlassIconButton(symbol: kind.symbolName, title: kind.label, isOn: state.shapeKind == kind) {
                        state.shapeKind = kind
                    }
                    .accessibilityIdentifier("shapeKind.\(kind.rawValue)")
                }
            }
            GlassGroup(scrollsHorizontally: true) {
                ColorWell(state: state)
                if state.shapeKind.canFill {
                    GlassIconButton(
                        symbol: state.shapeIsFilled ? "square.fill" : "square", label: "Options.ShapeFilled",
                        isOn: state.shapeIsFilled
                    ) {
                        state.shapeIsFilled.toggle()
                    }
                }
                if !state.shapeIsFilled || !state.shapeKind.canFill {
                    OptionSlider(
                        value: Binding(
                            get: { BrushSizeScale.position(for: state.shapeLineWidth) },
                            set: { state.shapeLineWidth = BrushSizeScale.size(at: $0) }
                        ),
                        label: "Options.LineWidth", valueText: "\(Int(state.shapeLineWidth.rounded())) px"
                    )
                }
            }
        }
    }
}

/// Brush sizes run from one pixel to hundreds; a slider following the
/// square root gives the small sizes, which need the most care, room.
enum BrushSizeScale {
    static func position(for size: Double) -> Double {
        let range = BrushSettings.sizeRange
        return sqrt((size - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    static func size(at position: Double) -> Double {
        let range = BrushSettings.sizeRange
        return (range.lowerBound + position * position * (range.upperBound - range.lowerBound)).rounded()
    }
}

/// A short slider with its value beside it, sized to sit in a glass bar.
struct OptionSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let label: LocalizedStringKey
    let valueText: String

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range)
                .frame(width: 120)
                .accessibilityLabel(label)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: EditorToolbarMetrics.controlSize)
    }
}


/// Everything about the brush or eraser that does not fit the bar.
private struct BrushSettingsButton: View {
    @Bindable var state: EditorState
    @State private var isPresented = false
    @State private var isNaming = false
    @State private var newName = ""
    @State private var isPickingTipPhoto = false
    @State private var tipPhoto: PhotosPickerItem?
    @State private var isPickingTipFile = false
    private let library = BrushLibrary.shared
    private let customTips = CustomBrushTipLibrary.shared

    /// A built-in tip, or one of the imported ones.
    private enum TipChoice: Hashable {
        case builtIn(BrushTip)
        case custom(UUID)
    }

    private var tipChoice: Binding<TipChoice> {
        Binding(
            get: {
                let brush = state.currentBrush
                guard brush.tip == .custom, let id = brush.customTip else { return .builtIn(brush.tip) }
                return .custom(id)
            },
            set: { choice in
                switch choice {
                case .builtIn(let tip):
                    state.currentBrush.tip = tip
                case .custom(let id):
                    state.currentBrush.tip = .custom
                    state.currentBrush.customTip = id
                }
            }
        )
    }

    var body: some View {
        GlassIconButton(symbol: "slider.horizontal.3", label: "Options.BrushSettings", isOn: isPresented) {
            isPresented = true
        }
        .popover(isPresented: $isPresented) {
            Form {
                if state.tool == .brush || state.tool == .eraser {
                    Section {
                        Picker("Brush.Tip", selection: tipChoice) {
                            ForEach(BrushTip.builtIn) { tip in
                                Label(tip.label, systemImage: tip.symbolName).tag(TipChoice.builtIn(tip))
                            }
                            if !customTips.tips.isEmpty {
                                Section("Brush.CustomTips") {
                                    ForEach(Array(customTips.tips.enumerated()), id: \.element) { index, id in
                                        customTipLabel(id, number: index + 1).tag(TipChoice.custom(id))
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("brushTip")
                        Menu {
                            // The pickers are presented from outside the menu,
                            // which is gone by the time one inside it would show.
                            Button("Brush.CustomTip.FromPhotos", systemImage: "photo.on.rectangle") { isPickingTipPhoto = true }
                            Button("Brush.CustomTip.FromFiles", systemImage: "folder") { isPickingTipFile = true }
                            if !customTips.tips.isEmpty {
                                Menu("Brush.CustomTip.Delete", systemImage: "trash") {
                                    ForEach(Array(customTips.tips.enumerated()), id: \.element) { index, id in
                                        Button(role: .destructive) { deleteTip(id) } label: {
                                            customTipLabel(id, number: index + 1)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Brush.CustomTip.Import", systemImage: "photo.badge.plus")
                        }
                        .accessibilityIdentifier("importBrushTip")
                        Menu {
                            ForEach(BrushPreset.builtIn) { preset in
                                presetButton(preset)
                            }
                            if !library.saved.isEmpty {
                                Section("Brush.Saved") {
                                    ForEach(library.saved) { preset in
                                        presetButton(preset)
                                    }
                                }
                                Menu("Brush.DeleteSaved", systemImage: "trash") {
                                    ForEach(library.saved) { preset in
                                        Button(preset.name, role: .destructive) { library.delete(preset) }
                                    }
                                }
                            }
                            Section {
                                Button("Brush.SaveCurrent", systemImage: "plus") {
                                    newName = ""
                                    isNaming = true
                                }
                            }
                        } label: {
                            Label("Brush.Library", systemImage: "paintbrush.pointed")
                        }
                        .accessibilityIdentifier("brushLibrary")
                    }
                }
                Section {
                    LabeledSlider(
                        label: "Options.Size",
                        value: Binding(
                            get: { BrushSizeScale.position(for: state.currentBrush.size) },
                            set: { state.currentBrush.size = BrushSizeScale.size(at: $0) }
                        ),
                        valueText: "\(Int(state.currentBrush.size.rounded())) px"
                    )
                    // The retouching brushes have a strength where others
                    // have an opacity; heal always heals fully, and a clone
                    // is laid down like paint.
                    if state.tool != .heal {
                        LabeledSlider(
                            label: state.tool.isRetouch && state.tool != .clone ? "Options.Strength" : "Options.Opacity",
                            value: $state.currentBrush.opacity,
                            valueText: "\(Int((state.currentBrush.opacity * 100).rounded()))%"
                        )
                    }
                    LabeledSlider(
                        label: "Options.Softness", value: $state.currentBrush.softness,
                        valueText: "\(Int((state.currentBrush.softness * 100).rounded()))%"
                    )
                }
                if state.tool == .brush || state.tool == .eraser {
                    Section("Brush.Dynamics") {
                        LabeledSlider(
                            label: "Options.Taper", value: $state.currentBrush.dynamics.taper,
                            valueText: "\(Int((state.currentBrush.dynamics.taper * 100).rounded()))%"
                        )
                        LabeledSlider(
                            label: "Options.SpeedThinning", value: $state.currentBrush.dynamics.speed,
                            valueText: "\(Int((state.currentBrush.dynamics.speed * 100).rounded()))%"
                        )
                        LabeledSlider(
                            label: "Options.Scatter", value: $state.currentBrush.dynamics.scatter,
                            valueText: "\(Int((state.currentBrush.dynamics.scatter * 100).rounded()))%"
                        )
                        LabeledSlider(
                            label: "Options.SizeJitter", value: $state.currentBrush.dynamics.sizeJitter,
                            valueText: "\(Int((state.currentBrush.dynamics.sizeJitter * 100).rounded()))%"
                        )
                        if state.tool == .brush {
                            LabeledSlider(
                                label: "Options.ColorJitter", value: $state.currentBrush.dynamics.colorJitter,
                                valueText: "\(Int((state.currentBrush.dynamics.colorJitter * 100).rounded()))%"
                            )
                        }
                        if state.currentBrush.tip.isStamped && !state.currentBrush.tip.followsStroke {
                            Toggle("Options.FollowsStroke", isOn: $state.currentBrush.dynamics.followsStroke)
                        }
                    }
                }
                if !state.isSmudging && state.tool != .liquify {
                    Section {
                        Toggle("Options.PencilPressure", isOn: $state.currentBrush.usesPressure)
                        if state.currentBrush.tip.isStamped {
                            Toggle("Options.PencilTilt", isOn: $state.currentBrush.usesTilt)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, minHeight: 340)
            .presentationCompactAdaptation(.popover)
            .alert("Brush.SaveCurrent", isPresented: $isNaming) {
                TextField("Brush.Name", text: $newName)
                Button("Common.Cancel", role: .cancel) {}
                Button("Brush.Save") { library.save(state.currentBrush, as: newName) }
            }
            .photosPicker(isPresented: $isPickingTipPhoto, selection: $tipPhoto, matching: .images)
            .onChange(of: tipPhoto) { _, item in
                guard let item else { return }
                tipPhoto = nil
                Task { importTip(await ImageImport.load([item])) }
            }
            .fileImporter(isPresented: $isPickingTipFile, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                Task { importTip(await ImageImport.load([url])) }
            }
        }
    }

    private func customTipLabel(_ id: UUID, number: Int) -> some View {
        Label {
            Text(String(format: String(localized: "Brush.Tip.CustomNumbered"), number))
        } icon: {
            // Shown at about a symbol's size.
            Image(uiImage: UIImage(
                cgImage: BrushTipImage.tinted(.custom, softness: 0, color: .black, custom: id),
                scale: Double(CustomBrushTips.size) / 22, orientation: .up
            ))
        }
    }

    /// Makes the picture picked a tip and paints with it.
    private func importTip(_ loaded: (images: [ImageImport.Item], failed: Bool)) {
        guard let picture = loaded.images.first?.image, let id = try? customTips.add(picture) else {
            state.errorMessage = String(localized: "Error.TipImportFailed")
            return
        }
        tipChoice.wrappedValue = .custom(id)
    }

    private func deleteTip(_ id: UUID) {
        customTips.delete(id)
        if state.currentBrush.customTip == id {
            state.currentBrush.customTip = nil
            if state.currentBrush.tip == .custom { state.currentBrush.tip = .round }
        }
    }

    private func presetButton(_ preset: BrushPreset) -> some View {
        Button(preset.name, systemImage: preset.tip.symbolName) {
            state.currentBrush = preset.applied(to: state.currentBrush)
        }
    }
}

/// Exact scale and angle for the layer being moved.
private struct TransformSettingsButton: View {
    @Bindable var state: EditorState
    @State private var isPresented = false

    var body: some View {
        GlassIconButton(symbol: "slider.horizontal.3", label: "Options.Transform", isOn: isPresented) {
            isPresented = true
        }
        .popover(isPresented: $isPresented) {
            let transform = state.activeLayer?.transform
            Form {
                Section {
                    LabeledSlider(
                        label: "Options.Scale",
                        value: Binding(
                            get: { transform?.uniformScale ?? 1 },
                            set: { value in state.updateTransform { $0.uniformScale = value } }
                        ),
                        range: 0.05...4,
                        valueText: "\(Int(((transform?.uniformScale ?? 1) * 100).rounded()))%"
                    )
                    LabeledSlider(
                        label: "Options.Rotation",
                        value: Binding(
                            get: { (transform?.rotation ?? 0) * 180 / .pi },
                            set: { value in state.updateTransform { $0.rotation = value * .pi / 180 } }
                        ),
                        range: -180...180,
                        valueText: "\(Int((((transform?.rotation ?? 0) * 180 / .pi)).rounded()))°"
                    )
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, minHeight: 220)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// A slider in a form, its name above and its value at the end.
struct LabeledSlider: View {
    let label: Text
    var systemImage: String?
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let valueText: String

    init(
        label: LocalizedStringKey, systemImage: String? = nil, value: Binding<Double>,
        range: ClosedRange<Double> = 0...1, valueText: String
    ) {
        self.init(title: Text(label), systemImage: systemImage, value: value, range: range, valueText: valueText)
    }

    /// For names already looked up, such as an adjustment's.
    init(
        title: Text, systemImage: String? = nil, value: Binding<Double>,
        range: ClosedRange<Double> = 0...1, valueText: String
    ) {
        label = title
        self.systemImage = systemImage
        _value = value
        self.range = range
        self.valueText = valueText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let systemImage {
                    Label { label } icon: { Image(systemName: systemImage) }
                } else {
                    label
                }
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(label)
                .accessibilityValue(valueText)
        }
    }
}

/// What can be done with the selection.
struct SelectionMenu: View {
    @Bindable var state: EditorState

    var body: some View {
        GlassMenuButton(symbol: "ellipsis", label: "Options.SelectionActions") {
            SelectionMenuItems(state: state)
        }
        .accessibilityIdentifier("selectionMenu")
    }
}

struct SelectionMenuItems: View {
    @Bindable var state: EditorState

    var body: some View {
        let hasSelection = state.selection != nil
        Section {
            Button("Select.All", systemImage: "selection.pin.in.out") { state.selectAll() }
            Button("Select.Subject", systemImage: "person.and.background.dotted") { state.selectObject(at: nil) }
            Button("Select.Deselect", systemImage: "xmark.square") { state.deselect() }
                .disabled(!hasSelection)
            Button("Select.Invert", systemImage: "square.on.square.intersection.dashed") { state.invertSelection() }
                .disabled(!hasSelection)
        }
        Section {
            Button("Select.CopyToLayer", systemImage: "square.on.square") { state.copySelectionToNewLayer(cut: false) }
            Button("Select.CutToLayer", systemImage: "scissors") { state.copySelectionToNewLayer(cut: true) }
            Button("Select.Fill", systemImage: "drop.fill") { state.fillSelection() }
            Button("Select.FillFromSurroundings", systemImage: "bandage") { state.fillSelectionFromSurroundings() }
            Button("Select.Clear", systemImage: "trash", role: .destructive) { state.clearSelection() }
        }
        .disabled(!hasSelection)
        Section {
            Menu("Select.Modify", systemImage: "slider.horizontal.below.rectangle") {
                ForEach(SelectionModification.allCases) { modification in
                    Button(modification.label, systemImage: modification.symbolName) {
                        state.pendingSelectionEdit = .modify(modification)
                    }
                    .accessibilityIdentifier("selectionModify.\(modification.rawValue)")
                }
            }
            Button("Select.RefineEdge", systemImage: "wand.and.sparkles") { state.pendingSelectionEdit = .refine }
            Button("Select.Stroke", systemImage: "pencil.and.outline") { state.pendingSelectionEdit = .stroke }
        }
        .disabled(!hasSelection)
        Section {
            Button("Select.CropToSelection", systemImage: "crop") { state.cropToSelection() }
                .disabled(!hasSelection)
        }
    }
}

/// A colour well for one of a vector path's colours.
private struct VectorColorWell: View {
    let color: RGBAColor
    let set: (RGBAColor) -> Void

    var body: some View {
        ColorPicker(
            "Options.Color",
            selection: Binding(get: { color.color }, set: { set(RGBAColor($0)) }),
            supportsOpacity: true
        )
        .labelsHidden()
        .frame(width: EditorToolbarMetrics.controlSize, height: EditorToolbarMetrics.controlSize)
    }
}

/// Sets or changes the text running along the picked point's path.
private struct PathTextButton: View {
    @Bindable var state: EditorState
    @State private var isPresented = false
    @State private var draft = ""

    var body: some View {
        GlassIconButton(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", label: "Options.PathText",
                        isOn: state.selectedVectorPath?.text != nil) {
            draft = state.selectedVectorPath?.text?.string ?? ""
            isPresented = true
        }
        .accessibilityIdentifier("pathText")
        .popover(isPresented: $isPresented) {
            Form {
                Section {
                    TextField("Text.Placeholder", text: $draft)
                        .onSubmit { state.setPathText(draft) }
                        .accessibilityIdentifier("pathTextField")
                    Button("Options.PathText.Apply") { state.setPathText(draft) }
                }
                if let text = state.selectedVectorPath?.text {
                    Section {
                        LabeledSlider(
                            label: "Text.Size",
                            value: Binding(
                                get: { BrushSizeScale.position(for: text.fontSize) },
                                set: { value in state.updatePathText { $0.fontSize = max(4, BrushSizeScale.size(at: value)) } }
                            ),
                            valueText: "\(Int(text.fontSize.rounded())) px"
                        )
                        LabeledSlider(
                            label: "Options.PathText.Start",
                            value: Binding(get: { text.start }, set: { value in state.updatePathText { $0.start = value } }),
                            valueText: "\(Int((text.start * 100).rounded()))%"
                        )
                        ColorPicker("Text.Color", selection: Binding(
                            get: { text.color.color }, set: { value in state.updatePathText { $0.color = RGBAColor(value) } }
                        ))
                        Toggle("Text.Bold", isOn: Binding(
                            get: { text.isBold }, set: { value in state.updatePathText { $0.isBold = value } }
                        ))
                        Button("Options.PathText.Remove", role: .destructive) { state.setPathText("") }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, minHeight: 360)
            .presentationCompactAdaptation(.popover)
        }
    }
}
