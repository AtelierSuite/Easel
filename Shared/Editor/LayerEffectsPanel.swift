import Paintbrush
import SwiftUI

/// The active layer's styles: shadows, glows, an outline, a bevel and
/// overlays, each worked out from the layer's shape whenever it is drawn,
/// so they follow what is painted on it and stay editable.
struct LayerEffectsPanel: View {
    @Bindable var state: EditorState

    var body: some View {
        Group {
            if let layer = state.activeLayer {
                effectList(layer)
            } else {
                ContentUnavailableView("Error.NoLayer", systemImage: "square.3.layers.3d")
            }
        }
        .panelActions(confirm: { state.presentedPanel = nil })
    }

    private func effectList(_ layer: Layer) -> some View {
        PanelList {
            // In the order they stack, top first, as in the Layers panel.
            ForEach(LayerEffect.Kind.allCases.reversed()) { kind in
                if let effect = layer.effects.first(where: { $0.kind == kind }) {
                    Section {
                        EffectRow(effect: effect, state: state)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if layer.effects.isEmpty {
                ContentUnavailableView {
                    Label("LayerEffects.Empty", systemImage: EditorPanel.effects.symbolName)
                } description: {
                    Text("LayerEffects.Empty.Detail")
                }
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            addBar(layer)
        }
    }

    @Environment(\.panelPlacement) private var placement

    @ViewBuilder
    private func addBar(_ layer: Layer) -> some View {
        #if os(macOS)
        if placement == .inspector {
            InspectorAddBar {
                Menu {
                    addItems(layer)
                } label: {
                    Label("LayerEffects.Add", systemImage: "plus")
                }
                .accessibilityIdentifier("addEffect")
            } moreItems: {
                effectActions(layer)
            }
        } else {
            standardAddBar(layer)
        }
        #else
        standardAddBar(layer)
        #endif
    }

    private func standardAddBar(_ layer: Layer) -> some View {
        HStack(spacing: 10) {
            Menu {
                addItems(layer)
            } label: {
                Label("LayerEffects.Add", systemImage: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier("addEffect")
            Spacer()
            GlassGroup {
                GlassMenuButton(symbol: "ellipsis", label: "Layers.More") {
                    effectActions(layer)
                }
                .accessibilityIdentifier("effectsMore")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func addItems(_ layer: Layer) -> some View {
        ForEach(LayerEffect.Kind.allCases) { kind in
            Button {
                state.addEffect(kind)
            } label: {
                Label {
                    Text(verbatim: kind.label)
                } icon: {
                    Image(systemName: kind.symbolName)
                }
            }
            .disabled(layer.effects.contains { $0.kind == kind && $0.isEnabled })
            .accessibilityIdentifier("addEffect.\(kind.rawValue)")
        }
    }

    @ViewBuilder
    private func effectActions(_ layer: Layer) -> some View {
        Button("LayerEffects.Apply", systemImage: "square.and.arrow.down.on.square") {
            state.applyFilters(of: layer.id)
        }
        .disabled(!layer.hasActiveEffects || layer.isLocked)
        Button("LayerEffects.RemoveAll", systemImage: "trash", role: .destructive) {
            state.updateActiveLayer { $0.effects = [] }
        }
        .disabled(layer.effects.isEmpty)
    }
}

/// One effect: what it is, whether it is on, and its settings.
private struct EffectRow: View {
    let effect: LayerEffect
    let state: EditorState

    @Environment(\.panelPlacement) private var placement

    @ViewBuilder
    private var header: some View {
        #if os(macOS)
        if placement == .inspector {
            InspectorItemHeader(
                title: Text(verbatim: effect.kind.label),
                isOn: Binding(
                    get: { effect.isEnabled },
                    set: { value in state.updateEffect(effect.id) { $0.isEnabled = value } }
                ),
                menuIdentifier: "effectMenu.\(effect.kind.rawValue)"
            ) {
                Button("LayerEffects.Remove", systemImage: "trash", role: .destructive) {
                    state.removeEffect(effect.id)
                }
                .accessibilityIdentifier("removeEffect.\(effect.kind.rawValue)")
            }
            .accessibilityIdentifier("effectEnabled.\(effect.kind.rawValue)")
        } else {
            standardHeader
        }
        #else
        standardHeader
        #endif
    }

    private var standardHeader: some View {
        let kind = effect.kind
        return HStack(spacing: 10) {
            Image(systemName: kind.symbolName)
                .foregroundStyle(effect.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text(verbatim: kind.label)
                .font(.headline)
            Spacer()
            Button(role: .destructive) {
                state.removeEffect(effect.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("LayerEffects.Remove")
            .accessibilityIdentifier("removeEffect.\(kind.rawValue)")
            Button {
                state.updateEffect(effect.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: effect.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(effect.isEnabled ? Color.primary : Color.secondary)
                    .frame(width: 36, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(effect.isEnabled ? "LayerFilters.Hide" : "LayerFilters.Show")
            .accessibilityIdentifier("effectEnabled.\(kind.rawValue)")
        }
    }

    var body: some View {
        let kind = effect.kind
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                if kind.hasColor || (kind.hasPattern && effect.pattern.preset != nil) {
                    HStack(spacing: 16) {
                        ColorPicker("LayerEffects.Color", selection: colorBinding(\.color), supportsOpacity: false)
                        if kind.hasSecondColor {
                            ColorPicker("LayerEffects.EndColor", selection: colorBinding(\.secondColor), supportsOpacity: false)
                        }
                    }
                    .font(.subheadline)
                }
                if kind.hasPattern {
                    patternRow
                }
                if kind.canInvert {
                    Toggle("LayerEffects.Invert", isOn: Binding(
                        get: { effect.isInverted },
                        set: { value in state.updateEffect(effect.id) { $0.isInverted = value } }
                    ))
                    .font(.subheadline)
                }
                if kind.hasPosition {
                    Picker("LayerEffects.Position", selection: Binding(
                        get: { effect.position },
                        set: { value in state.updateEffect(effect.id) { $0.position = value } }
                    )) {
                        ForEach(LayerEffect.Position.allCases) { position in
                            Text(verbatim: position.label).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                LabeledSlider(
                    label: "LayerEffects.Opacity", value: binding(\.opacity),
                    valueText: "\(Int((effect.opacity * 100).rounded()))%"
                )
                if kind.hasSize {
                    LabeledSlider(
                        label: kind == .stroke ? "LayerEffects.Width" : "LayerEffects.Size",
                        value: binding(\.size), range: 0...maxLength,
                        valueText: "\(Int(effect.size.rounded())) px"
                    )
                }
                if kind.hasDistance {
                    LabeledSlider(
                        label: "LayerEffects.Distance", value: binding(\.distance), range: 0...maxLength,
                        valueText: "\(Int(effect.distance.rounded())) px"
                    )
                }
                if kind.hasAngle {
                    LabeledSlider(
                        label: "LayerFilters.Angle", value: binding(\.angle), range: -180...180,
                        valueText: "\(Int(effect.angle.rounded()))°"
                    )
                }
            }
            .disabled(!effect.isEnabled)
            .opacity(effect.isEnabled ? 1 : 0.5)
        }
        .padding(.vertical, 4)
    }

    /// Which tile the overlay repeats, and how large.
    private var patternRow: some View {
        HStack(spacing: 12) {
            Menu {
                Section("Pattern.BuiltIn") {
                    ForEach(PatternChoice.Preset.allCases) { preset in
                        Button {
                            state.updateEffect(effect.id) { $0.pattern = PatternChoice(preset: preset, scale: $0.pattern.scale) }
                        } label: {
                            Label(LocalizedStringKey(preset.labelKey), systemImage: preset.symbolName)
                        }
                    }
                }
                if !state.composition.patterns.isEmpty {
                    Section("Pattern.Document") {
                        ForEach(state.composition.patterns) { swatch in
                            Button(swatch.name, systemImage: "photo") {
                                let swatches = state.composition.patterns
                                state.updateEffect(effect.id) {
                                    $0.pattern = PatternChoice(preset: nil, swatchID: swatch.id, scale: $0.pattern.scale)
                                        .carryingTile(from: swatches)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label {
                    patternName
                } icon: {
                    Image(systemName: effect.pattern.preset?.symbolName ?? "photo")
                }
                .font(.subheadline)
            }
            .accessibilityIdentifier("effectPattern")
            Spacer()
            Picker("Pattern.Scale", selection: Binding(
                get: { effect.pattern.scale },
                set: { value in state.updateEffect(effect.id) { $0.pattern.scale = value } }
            )) {
                ForEach(Self.patternScales(including: effect.pattern.scale), id: \.self) { scale in
                    Text(verbatim: "\(Int((scale * 100).rounded()))%").tag(scale)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var patternName: Text {
        if let preset = effect.pattern.preset { return Text(LocalizedStringKey(preset.labelKey)) }
        let name = state.composition.patterns.first { $0.id == effect.pattern.swatchID }?.name
        return name.map { Text(verbatim: $0) } ?? Text("Pattern.Document")
    }

    /// The usual sizes, and a file's own if it is none of them.
    private static func patternScales(including scale: Double) -> [Double] {
        let scales = [0.25, 0.5, 1, 2, 4]
        return scales.contains(scale) ? scales : (scales + [scale]).sorted()
    }

    /// Lengths reach a tenth of the picture's longer side.
    private var maxLength: Double {
        let size = state.composition.size
        return max(50, (max(size.width, size.height) / 10).rounded())
    }

    private func binding(_ keyPath: WritableKeyPath<LayerEffect, Double>) -> Binding<Double> {
        Binding(
            get: { effect[keyPath: keyPath] },
            set: { value in state.updateEffect(effect.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<LayerEffect, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { effect[keyPath: keyPath].color },
            set: { value in state.updateEffect(effect.id) { $0[keyPath: keyPath] = RGBAColor(value) } }
        )
    }
}
