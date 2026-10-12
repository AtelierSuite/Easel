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
        List {
            // In the order they stack, top first, as in the Layers panel.
            ForEach(LayerEffect.Kind.allCases.reversed()) { kind in
                if let effect = layer.effects.first(where: { $0.kind == kind }) {
                    Section {
                        EffectRow(effect: effect, state: state)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
            HStack(spacing: 10) {
                Menu {
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
                        Button("LayerEffects.Apply", systemImage: "square.and.arrow.down.on.square") {
                            state.applyFilters(of: layer.id)
                        }
                        .disabled(!layer.hasActiveEffects || layer.isLocked)
                        Button("LayerEffects.RemoveAll", systemImage: "trash", role: .destructive) {
                            state.updateActiveLayer { $0.effects = [] }
                        }
                        .disabled(layer.effects.isEmpty)
                    }
                    .accessibilityIdentifier("effectsMore")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
    }
}

/// One effect: what it is, whether it is on, and its settings.
private struct EffectRow: View {
    let effect: LayerEffect
    let state: EditorState

    var body: some View {
        let kind = effect.kind
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
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
            Group {
                if kind.hasColor {
                    HStack(spacing: 16) {
                        ColorPicker("LayerEffects.Color", selection: colorBinding(\.color), supportsOpacity: false)
                        if kind.hasSecondColor {
                            ColorPicker("LayerEffects.EndColor", selection: colorBinding(\.secondColor), supportsOpacity: false)
                        }
                    }
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
