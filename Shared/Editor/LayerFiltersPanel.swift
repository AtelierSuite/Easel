import SwiftUI

/// The active layer's filters: a chain run top to bottom over its pixels,
/// every link of which stays editable. Filters can be turned off, dragged
/// into a different order, swiped away, or painted in for good.
struct LayerFiltersPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        Group {
            if let layer = state.activeLayer {
                filterList(layer)
            } else {
                ContentUnavailableView("Error.NoLayer", systemImage: "square.3.layers.3d")
            }
        }
        .panelActions(confirm: { state.presentedPanel = nil })
    }

    private func filterList(_ layer: Layer) -> some View {
        List {
            Section {
                ForEach(Array(layer.filters.enumerated()), id: \.element.id) { index, filter in
                    FilterRow(
                        filter: filter, state: state,
                        canMoveUp: index > 0, canMoveDown: index < layer.filters.count - 1
                    )
                }
                // No swipe to delete: a slider dragged along its track would
                // set it off. Removing is in each filter's menu.
                .onMove { state.moveFilters(from: $0, to: $1) }
            } footer: {
                if !layer.filters.isEmpty { Text("LayerFilters.Footer") }
            }
            if !layer.filters.isEmpty {
                Section {
                    FilterMaskRow(layer: layer, state: state)
                } footer: {
                    Text("FilterMask.Footer")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Under the same bar as when there are filters: a menu to add one
        // placed in the empty view itself would not open.
        .overlay {
            if layer.filters.isEmpty {
                ContentUnavailableView {
                    Label("LayerFilters.Empty", systemImage: "camera.filters")
                } description: {
                    Text("LayerFilters.Empty.Detail")
                }
                .allowsHitTesting(false)
            }
        }
        // At the top, where a half-height sheet still shows them.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                AddFilterMenu(state: state) {
                    Label("LayerFilters.Add", systemImage: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("addFilter")
                Spacer()
                GlassGroup {
                    GlassMenuButton(symbol: "ellipsis", label: "Layers.More") {
                        Button("LayerFilters.ApplyAll", systemImage: "square.and.arrow.down.on.square") {
                            state.applyFilters(of: layer.id)
                        }
                        .disabled(!layer.hasActiveFilters || layer.isLocked)
                        Button("LayerFilters.RemoveAll", systemImage: "trash", role: .destructive) {
                            state.updateActiveLayer { layer in
                                layer.filters = []
                                layer.filterMask = nil
                            }
                            state.isEditingFilterMask = false
                        }
                    }
                    .accessibilityIdentifier("filtersMore")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
    }
}

/// Where the filters show: a mask painted like a layer's, hiding them
/// where it is dark.
private struct FilterMaskRow: View {
    let layer: Layer
    @Bindable var state: EditorState

    var body: some View {
        if let mask = layer.filterMask {
            HStack(spacing: 12) {
                Image(decorative: mask.preview(maxPixelSize: 96), scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 6))
                    // A mask showing everything is all white.
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                    .opacity(mask.isEnabled ? 1 : 0.4)
                Toggle("FilterMask.Paint", systemImage: "paintbrush.pointed", isOn: $state.isEditingFilterMask)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("paintFilterMask")
                Spacer()
                Menu {
                    Button("Mask.Invert", systemImage: "circle.lefthalf.filled.inverse") { state.invertFilterMask() }
                    Button("FilterMask.Delete", systemImage: "trash", role: .destructive) { state.deleteFilterMask() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Layers.More")
                .accessibilityIdentifier("filterMaskMenu")
                Button {
                    state.setFilterMaskEnabled(!mask.isEnabled)
                } label: {
                    Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                        .foregroundStyle(mask.isEnabled ? Color.primary : Color.secondary)
                        .frame(width: 36, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(mask.isEnabled ? "FilterMask.Disable" : "FilterMask.Enable")
                .accessibilityIdentifier("filterMaskEnabled")
            }
        } else {
            Button("FilterMask.Add", systemImage: "circle.lefthalf.filled") { state.addFilterMask() }
                .disabled(layer.isLocked)
                .accessibilityIdentifier("addFilterMask")
        }
    }
}

/// One filter: what it is, whether it is on, and its settings. An
/// adjustment layer's filter is shown the same way, without the moves.
struct FilterRow: View {
    let filter: LayerFilter
    let state: EditorState
    var canMoveUp = false
    var canMoveDown = false
    var isAdjustment = false
    /// The colour band the HSL sliders change.
    @State private var band = 0
    @State private var histogram: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: filter.kind.symbolName)
                    .foregroundStyle(filter.isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(verbatim: filter.kind.label)
                    .font(.headline)
                Spacer()
                if !isAdjustment {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Layers.More")
                .accessibilityIdentifier("filterMenu.\(filter.kind.rawValue)")
                }
                // An eye, as for layers: a switch in a reorderable row loses
                // its taps to the row.
                Button {
                    state.updateFilter(filter.id) { $0.isEnabled.toggle() }
                } label: {
                    Image(systemName: filter.isEnabled ? "eye" : "eye.slash")
                        .foregroundStyle(filter.isEnabled ? Color.primary : Color.secondary)
                        .frame(width: 36, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(filter.isEnabled ? "LayerFilters.Hide" : "LayerFilters.Show")
                .accessibilityIdentifier("filterEnabled.\(filter.kind.rawValue)")
            }
            Group {
                if filter.kind == .levels { levelsControls }
                if filter.kind == .colorBalance { balanceControls }
                if filter.kind == .gradientMap { gradientControls }
                if filter.kind == .lensCorrection { lensControls }
                if filter.kind == .hsl { hslControls }
                if filter.kind == .replaceColor { replaceControls }
                if filter.kind == .curves {
                    CurveEditor(values: filter.curve ?? LayerFilter.straightCurve, histogram: histogram) { values in
                        state.updateFilter(filter.id) { filter in
                            filter.curve = values
                            // The combined curve now follows the five points.
                            if filter.curvePoints != nil { filter.curvePoints?[0] = [] }
                        }
                    }
                    .frame(height: 200)
                    .accessibilityIdentifier("curveEditor")
                }
                if !filter.kind.parameters.isEmpty { parameterControls }
                if filter.kind.hasAmount {
                LabeledSlider(
                    label: "LayerFilters.Amount",
                    value: binding(\.amount),
                    range: filter.kind.amountRange,
                    valueText: "\(Int((filter.amount * 100).rounded()))"
                )
                .accessibilityIdentifier("filterAmount.\(filter.kind.rawValue)")
                }
                if filter.kind.hasAngle {
                    LabeledSlider(
                        label: "LayerFilters.Angle", value: binding(\.angle), range: -180...180,
                        valueText: "\(Int(filter.angle.rounded()))°"
                    )
                }
                if filter.kind.hasRadius {
                    LabeledSlider(
                        label: "LayerFilters.Radius", value: optionalBinding(\.radius, default: 0.3),
                        valueText: "\(Int(((filter.radius ?? 0.3) * 100).rounded()))"
                    )
                }
                if filter.kind.hasCenter {
                    LabeledSlider(
                        label: "LayerFilters.CenterX", value: binding(\.centerX),
                        valueText: "\(Int((filter.centerX * 100).rounded()))%"
                    )
                    LabeledSlider(
                        label: "LayerFilters.CenterY", value: binding(\.centerY),
                        valueText: "\(Int((filter.centerY * 100).rounded()))%"
                    )
                }
            }
            .disabled(!filter.isEnabled)
            .opacity(filter.isEnabled ? 1 : 0.5)
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems }
        .task(id: state.activeLayer?.image.id) {
            guard filter.kind == .levels || filter.kind == .curves else { return }
            histogram = state.histogramForActiveLayer()
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !isAdjustment { filterMenuItems }
    }

    @ViewBuilder
    private var filterMenuItems: some View {
        Section {
            Button("Layers.MoveUp", systemImage: "arrow.up") { move(by: -1) }
                .disabled(!canMoveUp)
            Button("Layers.MoveDown", systemImage: "arrow.down") { move(by: 1) }
                .disabled(!canMoveDown)
        }
        Button("LayerFilters.Remove", systemImage: "trash", role: .destructive) {
            state.removeFilter(filter.id)
        }
    }

    private func move(by offset: Int) {
        guard let index = state.activeLayer?.filters.firstIndex(where: { $0.id == filter.id }) else { return }
        // `move(fromOffsets:toOffset:)` counts the destination before removal.
        state.moveFilters(from: [index], to: offset > 0 ? index + 2 : index - 1)
    }

    /// Controls for each of a filter's own settings.
    @ViewBuilder
    private var parameterControls: some View {
        if filter.kind == .custom {
            customControls
        } else {
            settingControls
        }
        if filter.kind == .shear { shearControls }
        if filter.kind.hasColor, filter.kind != .blackAndWhite || filter.value(6) >= 0.5 {
            ColorPicker(filter.kind.hasBackgroundColor ? "LayerFilters.Foreground" : "LayerFilters.Color", selection: Binding(
                get: { (filter.color ?? filter.kind.defaultColor ?? .white).color },
                set: { color in state.updateFilter(filter.id) { $0.color = RGBAColor(color) } }
            ), supportsOpacity: false)
            .font(.subheadline)
        }
        if filter.kind.hasBackgroundColor {
            ColorPicker("LayerFilters.Background", selection: Binding(
                get: { (filter.backgroundColor ?? .white).color },
                set: { color in state.updateFilter(filter.id) { $0.backgroundColor = RGBAColor(color) } }
            ), supportsOpacity: false)
            .font(.subheadline)
        }
    }

    /// How far each of Shear's points pushes its row across, top first.
    @ViewBuilder
    private var shearControls: some View {
        let points = filter.shearPoints
        ForEach(points.indices, id: \.self) { index in
            LabeledSlider(
                label: "LayerFilters.Point \(index + 1)",
                value: Binding(
                    get: { points[index].x },
                    set: { value in
                        state.updateFilter(filter.id) { filter in
                            var moved = filter.shearPoints
                            moved[index].x = value
                            filter.curvePoints = [moved.flatMap { [$0.x, $0.y] }]
                        }
                    }
                ),
                range: -64...64, valueText: "\(Int(points[index].x.rounded()))"
            )
        }
    }

    /// Custom's five by five weights, its divisor and its offset.
    private var customControls: some View {
        VStack(spacing: 6) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<5, id: \.self) { row in
                    GridRow {
                        ForEach(0..<5, id: \.self) { column in
                            numberField(index: row * 5 + column)
                        }
                    }
                }
            }
            HStack {
                Text("LayerFilters.Scale").font(.subheadline)
                numberField(index: 25)
                Text("LayerFilters.Offset").font(.subheadline)
                numberField(index: 26)
            }
        }
    }

    private func numberField(index: Int) -> some View {
        TextField("", value: Binding(
            get: { Int(filter.value(index).rounded()) },
            set: { newValue in state.updateFilter(filter.id) { $0.setValue(Double(newValue), at: index) } }
        ), format: .number)
        .multilineTextAlignment(.center)
        .keyboardType(.numbersAndPunctuation)
        .textFieldStyle(.roundedBorder)
        .font(.subheadline.monospacedDigit())
        .accessibilityIdentifier("customWeight.\(index)")
    }

    @ViewBuilder
    private var settingControls: some View {
        let parameters = filter.kind.parameters
        ForEach(parameters.indices, id: \.self) { index in
            let parameter = parameters[index]
            let value = Binding(
                get: { filter.value(index) },
                set: { newValue in state.updateFilter(filter.id) { $0.setValue(newValue, at: index) } }
            )
            switch parameter.style {
            case .toggle:
                Toggle(LocalizedStringKey(parameter.labelKey), isOn: Binding(
                    get: { value.wrappedValue >= 0.5 }, set: { value.wrappedValue = $0 ? 1 : 0 }
                ))
                .font(.subheadline)
            case .choice(let keys):
                Picker(LocalizedStringKey(parameter.labelKey), selection: Binding(
                    get: { Int(value.wrappedValue.rounded()) }, set: { value.wrappedValue = Double($0) }
                )) {
                    ForEach(keys.indices, id: \.self) { choice in
                        Text(LocalizedStringKey(keys[choice])).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
            default:
                LabeledSlider(
                    label: LocalizedStringKey(parameter.labelKey), value: value, range: parameter.range,
                    valueText: valueText(value.wrappedValue, style: parameter.style)
                )
            }
        }
    }

    private func valueText(_ value: Double, style: FilterParameter.Style) -> String {
        switch style {
        case .integer: return "\(Int(value.rounded()))"
        case .decimal: return String(format: "%.2f", value)
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .signedPercent: return "\(Int(value.rounded()))%"
        case .degrees: return "\(Int(value.rounded()))°"
        case .length:
            // In the layer's own pixels.
            let size = state.activeLayer?.image.size ?? .zero
            return String(format: "%.1f px", value * max(size.width, size.height) / 1000)
        case .choice, .toggle: return ""
        }
    }

    @ViewBuilder
    private var levelsControls: some View {
        HistogramView(values: histogram)
            .frame(height: 64)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
        LabeledSlider(
            label: "LayerFilters.Black", value: optionalBinding(\.black, default: 0), range: 0...0.9,
            valueText: "\(Int(((filter.black ?? 0) * 255).rounded()))"
        )
        LabeledSlider(
            label: "LayerFilters.Gamma", value: optionalBinding(\.gamma, default: 1), range: 0.2...3,
            valueText: String(format: "%.2f", filter.gamma ?? 1)
        )
        LabeledSlider(
            label: "LayerFilters.White", value: optionalBinding(\.white, default: 1), range: 0.1...1,
            valueText: "\(Int(((filter.white ?? 1) * 255).rounded()))"
        )
    }

    @ViewBuilder
    private var hslControls: some View {
        let hues = LayerFilter.hslBandHues
        HStack(spacing: 6) {
            ForEach(hues.indices, id: \.self) { index in
                Button {
                    band = index
                } label: {
                    Circle()
                        .fill(Color(hue: hues[index], saturation: 0.85, brightness: 0.95))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: band == index ? 2 : 0).padding(-3))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: "\(Int(hues[index] * 360))°"))
                .accessibilityIdentifier("hslBand.\(index)")
            }
        }
        let labels: [LocalizedStringKey] = ["LayerFilters.Hue", "Adjust.Saturation", "LayerFilters.Lightness"]
        ForEach(0..<3, id: \.self) { part in
            LabeledSlider(
                label: labels[part],
                value: Binding(
                    get: { (filter.hslBands ?? LayerFilter.neutralHSL)[band * 3 + part] },
                    set: { value in
                        state.updateFilter(filter.id) { filter in
                            var bands = filter.hslBands ?? LayerFilter.neutralHSL
                            bands[band * 3 + part] = value
                            filter.hslBands = bands
                        }
                    }
                ),
                range: -1...1,
                valueText: "\(Int(((filter.hslBands ?? LayerFilter.neutralHSL)[band * 3 + part] * 100).rounded()))"
            )
        }
    }

    @ViewBuilder
    private var replaceControls: some View {
        ColorPicker("LayerFilters.ReplaceSource", selection: colorBinding(\.replaceSource, default: .init(red: 1, green: 0, blue: 0)), supportsOpacity: false)
            .font(.subheadline)
        LabeledSlider(
            label: "LayerFilters.Fuzziness", value: binding(\.amount), range: 0.02...1,
            valueText: "\(Int((filter.amount * 100).rounded()))"
        )
        let labels: [LocalizedStringKey] = ["LayerFilters.Hue", "Adjust.Saturation", "LayerFilters.Lightness"]
        ForEach(0..<3, id: \.self) { part in
            LabeledSlider(
                label: labels[part],
                value: Binding(
                    get: { (filter.replaceShift ?? [0, 0, 0])[part] },
                    set: { value in
                        state.updateFilter(filter.id) { filter in
                            var shift = filter.replaceShift ?? [0, 0, 0]
                            shift[part] = value
                            filter.replaceShift = shift
                        }
                    }
                ),
                range: -1...1,
                valueText: "\(Int(((filter.replaceShift ?? [0, 0, 0])[part] * 100).rounded()))"
            )
        }
    }

    @ViewBuilder
    private var lensControls: some View {
        LabeledSlider(
            label: "LayerFilters.Distortion", value: binding(\.amount), range: -1...1,
            valueText: "\(Int((filter.amount * 100).rounded()))"
        )
        .accessibilityIdentifier("lensDistortion")
        LabeledSlider(
            label: "LayerFilters.Fringing", value: optionalBinding(\.fringing, default: 0), range: -1...1,
            valueText: "\(Int(((filter.fringing ?? 0) * 100).rounded()))"
        )
        LabeledSlider(
            label: "LayerFilters.VignetteFix", value: optionalBinding(\.vignetteFix, default: 0), range: -1...1,
            valueText: "\(Int(((filter.vignetteFix ?? 0) * 100).rounded()))"
        )
    }

    @ViewBuilder
    private var balanceControls: some View {
        let labels: [LocalizedStringKey] = ["LayerFilters.CyanRed", "LayerFilters.MagentaGreen", "LayerFilters.YellowBlue"]
        ForEach(0..<3, id: \.self) { channel in
            LabeledSlider(
                label: labels[channel],
                value: Binding(
                    get: { (filter.balance ?? LayerFilter.neutralBalance)[channel] },
                    set: { value in
                        state.updateFilter(filter.id) { filter in
                            var balance = filter.balance ?? LayerFilter.neutralBalance
                            balance[channel] = value
                            filter.balance = balance
                        }
                    }
                ),
                range: -1...1,
                valueText: "\(Int(((filter.balance ?? LayerFilter.neutralBalance)[channel] * 100).rounded()))"
            )
        }
    }

    @ViewBuilder
    private var gradientControls: some View {
        HStack(spacing: 16) {
            ColorPicker("LayerFilters.Shadows", selection: colorBinding(\.shadowColor, default: LayerFilter.defaultShadowColor), supportsOpacity: false)
            ColorPicker("LayerFilters.Highlights", selection: colorBinding(\.highlightColor, default: LayerFilter.defaultHighlightColor), supportsOpacity: false)
        }
        .font(.subheadline)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<LayerFilter, RGBAColor?>, default fallback: RGBAColor) -> Binding<Color> {
        Binding(
            get: { (filter[keyPath: keyPath] ?? fallback).color },
            set: { value in state.updateFilter(filter.id) { $0[keyPath: keyPath] = RGBAColor(value) } }
        )
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<LayerFilter, Double?>, default fallback: Double) -> Binding<Double> {
        Binding(
            get: { filter[keyPath: keyPath] ?? fallback },
            set: { value in state.updateFilter(filter.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<LayerFilter, Double>) -> Binding<Double> {
        Binding(
            get: { filter[keyPath: keyPath] },
            set: { value in state.updateFilter(filter.id) { $0[keyPath: keyPath] = value } }
        )
    }
}

/// The kinds of filter that can be added, grouped as tone and colour, then
/// blurs and mosaic.
struct AddFilterMenu<Label: View>: View {
    let state: EditorState
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            ForEach(Array(LayerFilter.Kind.groups.enumerated()), id: \.offset) { _, kinds in
                Section {
                    ForEach(kinds) { kind in
                        Button {
                            state.addFilter(kind)
                        } label: {
                            SwiftUI.Label {
                                Text(verbatim: kind.label)
                            } icon: {
                                Image(systemName: kind.symbolName)
                            }
                        }
                        .accessibilityIdentifier("addFilter.\(kind.rawValue)")
                    }
                }
            }
        } label: {
            label
        }
    }
}

/// A tone curve with five points along it, each dragged up or down.
struct CurveEditor: View {
    let values: [Double]
    /// The picture's shades, drawn behind the curve.
    var histogram: [Double] = []
    let change: ([Double]) -> Void
    @State private var dragging: Int?

    /// Room around the plot so the knobs at its ends show whole.
    private static let inset = 8.0

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.inset, dy: Self.inset)
            Canvas { context, _ in
                var grid = Path()
                for step in 1..<4 {
                    let x = plot.minX + plot.width * Double(step) / 4, y = plot.minY + plot.height * Double(step) / 4
                    grid.move(to: CGPoint(x: x, y: plot.minY))
                    grid.addLine(to: CGPoint(x: x, y: plot.maxY))
                    grid.move(to: CGPoint(x: plot.minX, y: y))
                    grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                diagonal.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
                context.stroke(diagonal, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var curve = Path()
                let points = (0..<5).map { index in
                    CGPoint(x: plot.minX + Double(index) / 4 * plot.width, y: plot.minY + (1 - values[index]) * plot.height)
                }
                curve.move(to: points[0])
                // A smooth line through the points (Catmull-Rom).
                for index in 0..<4 {
                    let p0 = points[max(index - 1, 0)], p1 = points[index]
                    let p2 = points[index + 1], p3 = points[min(index + 2, 4)]
                    curve.addCurve(
                        to: p2,
                        control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                        control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                    )
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                for point in points {
                    let knob = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                    context.fill(knob, with: .color(.white))
                    context.stroke(knob, with: .color(.accentColor), lineWidth: 2)
                }
            }
            .background {
                HistogramView(values: histogram)
                    .padding(Self.inset)
            }
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let index = dragging ?? Int(((drag.startLocation.x - plot.minX) / plot.width * 4).rounded())
                dragging = min(max(index, 0), 4)
                var updated = values
                updated[dragging!] = min(max(1 - (drag.location.y - plot.minY) / plot.height, 0), 1)
                change(updated)
            }.onEnded { _ in dragging = nil })
        }
    }
}
