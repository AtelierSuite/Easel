import CoreImage
import Paintbrush
import SwiftUI

/// Tone and colour sliders for the active layer, tried on the canvas as they
/// move and kept only when confirmed — or, in the Mac's inspector, kept on
/// the layer as an Adjust filter as they move, to change or undo later.
struct AdjustmentsPanel: View {
    @Bindable var state: EditorState
    @Environment(\.panelPlacement) private var placement
    @State private var adjustments = Adjustments()
    @State private var isApplied = false

    /// The sliders' values: the layer's own Adjust filter where changes are
    /// kept as they are made, or those being tried out.
    private var values: Binding<Adjustments> {
        guard placement.keepsChangesLive else { return $adjustments }
        return Binding(
            get: { state.adjustFilter?.adjustments ?? Adjustments() },
            set: { state.setAdjustFilter($0) }
        )
    }

    var body: some View {
        if placement.keepsChangesLive {
            form
                .onDisappear { stopPickingNeutral() }
                .panelActions()
        } else {
            form
                .onChange(of: adjustments) { _, adjustments in
                    if adjustments.isIdentity {
                        state.cancelPreview()
                    } else {
                        state.preview { adjustments.apply(to: $0) }
                    }
                }
                .onDisappear {
                    if !isApplied { state.cancelPreview() }
                    stopPickingNeutral()
                }
                .interactiveDismissDisabled(!adjustments.isIdentity)
                .panelActions(
                    cancel: {
                        state.cancelPreview()
                        state.presentedPanel = nil
                    },
                    confirm: {
                        if !adjustments.isIdentity {
                            isApplied = true
                            let adjustments = adjustments
                            state.applyProcessing { adjustments.apply(to: $0) }
                        }
                        state.presentedPanel = nil
                    },
                    confirmIdentifier: "applyAdjustments"
                )
        }
    }

    private var form: some View {
        let values = values
        return Form {
            ForEach(Array(Adjustments.Key.sections.enumerated()), id: \.offset) { _, keys in
                Section {
                    ForEach(keys) { key in
                        LabeledSlider(
                            title: Text(verbatim: key.label),
                            systemImage: key.symbolName,
                            value: values[key],
                            range: key.range,
                            valueText: "\(Int((values.wrappedValue[key] * 100).rounded()))"
                        )
                        .typed(scale: 100)
                        .accessibilityIdentifier("adjust.\(key.rawValue)")
                    }
                }
            }
            Section {
                Button(state.isPickingNeutral ? "Adjust.PickingNeutral" : "Adjust.PickNeutral", systemImage: "eyedropper") {
                    pickNeutral()
                }
                .accessibilityIdentifier("pickNeutral")
                if let balance = values.wrappedValue.balance {
                    LabeledContent("Adjust.PickedBalance") {
                        HStack {
                            // The picked light's colour, which it takes away.
                            Circle()
                                .fill(Color(red: 1 / balance.red, green: 1 / balance.green, blue: 1 / balance.blue).opacity(0.9))
                                .frame(width: 18, height: 18)
                            Button("Adjust.RemoveBalance", systemImage: "xmark.circle.fill") { values.wrappedValue.balance = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Adjust.PickNeutral.Footer")
            }
            Section {
                Button("Adjust.Reset", role: .destructive) { values.wrappedValue = Adjustments() }
                    .disabled(values.wrappedValue.isIdentity)
            } footer: {
                if placement.keepsChangesLive {
                    Text("Adjust.Live.Footer")
                }
            }
        }
        .panelFormStyle()
    }

    private func stopPickingNeutral() {
        state.isPickingNeutral = false
        state.neutralPick = nil
    }
}

extension AdjustmentsPanel {
    /// Waits for a tap on something that should be grey, then sets warmth
    /// and tint to make it so.
    private func pickNeutral() {
        let values = values
        state.isPickingNeutral = true
        state.neutralPick = { color in
            Task {
                let balance = await Task.detached(priority: .userInitiated) {
                    Adjustments.neutralBalance(for: color)
                }.value
                values.wrappedValue.balance = balance
            }
        }
    }
}

/// One-tap looks and effects painted into the active layer, each shown on a
/// small copy of it — or, in the Mac's inspector, kept on the layer as a Look
/// filter, to change or undo later.
struct LooksPanel: View {
    @Bindable var state: EditorState
    @Environment(\.panelPlacement) private var placement
    @State private var preset: FilterPreset?
    @State private var intensity = 1.0
    @State private var thumbnails: [FilterPreset: CGImage] = [:]
    @State private var original: CGImage?
    @State private var isApplied = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    /// The look picked: the layer's own Look filter's where changes are kept
    /// as they are made, or the one being tried out.
    private var picked: FilterPreset? {
        placement.keepsChangesLive ? state.lookFilter?.lookPreset : preset
    }

    private var pickedIntensity: Binding<Double> {
        guard placement.keepsChangesLive else { return $intensity }
        return Binding(
            get: { state.lookFilter?.amount ?? 1 },
            set: { state.setLookFilter(state.lookFilter?.lookPreset, intensity: $0) }
        )
    }

    var body: some View {
        if placement.keepsChangesLive {
            grid
                .task(id: state.activeLayerID) { await makeThumbnails() }
                .panelActions()
        } else {
            grid
                .task(id: state.activeLayerID) { await makeThumbnails() }
                .onChange(of: preset) { _, _ in refreshPreview() }
                .onChange(of: intensity) { _, _ in refreshPreview() }
                .onDisappear {
                    if !isApplied { state.cancelPreview() }
                }
                .interactiveDismissDisabled(preset != nil)
                .panelActions(
                    cancel: {
                        state.cancelPreview()
                        state.presentedPanel = nil
                    },
                    confirm: {
                        if let preset {
                            isApplied = true
                            let intensity = intensity
                            state.applyProcessing { preset.apply(to: $0, intensity: intensity) }
                        }
                        state.presentedPanel = nil
                    },
                    confirmIdentifier: "applyFilter"
                )
        }
    }

    private var grid: some View {
        let intensity = pickedIntensity
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if picked != nil {
                    LabeledSlider(
                        label: "Filters.Intensity", value: intensity,
                        valueText: "\(Int((intensity.wrappedValue * 100).rounded()))%"
                    )
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("filterIntensity")
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    tile(nil, label: String(localized: "Filter.None"), image: original)
                }
                ForEach(FilterPreset.sections, id: \.titleKey) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(section.titleKey))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(section.presets) { preset in
                                tile(preset, label: preset.label, image: thumbnails[preset])
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func tile(_ value: FilterPreset?, label: String, image: CGImage?) -> some View {
        let isSelected = picked == value
        return Button {
            if placement.keepsChangesLive {
                state.setLookFilter(value, intensity: 1)
            } else {
                preset = value
                intensity = 1
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Checkerboard(squareSize: 6)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.\(value?.rawValue ?? "none")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func refreshPreview() {
        guard let preset else {
            state.cancelPreview()
            return
        }
        let intensity = intensity
        state.preview { preset.apply(to: $0, intensity: intensity) }
    }

    private func makeThumbnails() async {
        guard let layer = state.activeLayer else { return }
        let source = layer.image
        let made = await Task.detached(priority: .userInitiated) { () -> (CGImage, [FilterPreset: CGImage]) in
            let small = source.preview(maxPixelSize: 240)
            var results: [FilterPreset: CGImage] = [:]
            for preset in FilterPreset.allCases {
                results[preset] = ImageProcessing.apply({ preset.apply(to: $0, intensity: 1) }, to: small)
            }
            return (small, results)
        }.value
        original = made.0
        thumbnails = made.1
    }
}
