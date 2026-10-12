import SwiftUI

/// Gradients to start from: the brush colour fading out, or fixed runs of
/// colour.
enum GradientPreset: String, CaseIterable, Identifiable, Sendable {
    case fading, toWhite, blackToWhite, rainbow, sunset, ocean

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .fading: return "Gradient.Preset.Fading"
        case .toWhite: return "Gradient.Preset.ToWhite"
        case .blackToWhite: return "Gradient.Preset.BlackToWhite"
        case .rainbow: return "Gradient.Preset.Rainbow"
        case .sunset: return "Gradient.Preset.Sunset"
        case .ocean: return "Gradient.Preset.Ocean"
        }
    }

    /// The stops, with `color` standing for the brush colour.
    func stops(with color: RGBAColor) -> [PaintGradient.Stop] {
        func stop(_ location: Double, _ red: Double, _ green: Double, _ blue: Double) -> PaintGradient.Stop {
            PaintGradient.Stop(location: location, color: RGBAColor(red: red, green: green, blue: blue))
        }
        switch self {
        case .fading: return PaintGradient.fading(color).stops
        case .toWhite: return [PaintGradient.Stop(location: 0, color: color.withAlpha(1)), stop(1, 1, 1, 1)]
        case .blackToWhite: return [stop(0, 0, 0, 0), stop(1, 1, 1, 1)]
        case .rainbow:
            let warm: [PaintGradient.Stop] = [stop(0, 1, 0, 0), stop(0.17, 1, 0.6, 0), stop(0.33, 1, 1, 0)]
            let cool: [PaintGradient.Stop] = [stop(0.5, 0, 0.8, 0), stop(0.67, 0, 0.5, 1), stop(0.83, 0.3, 0, 0.8), stop(1, 0.6, 0, 0.7)]
            return warm + cool
        case .sunset: return [stop(0, 0.25, 0.1, 0.45), stop(0.5, 0.95, 0.35, 0.4), stop(1, 1, 0.8, 0.35)]
        case .ocean: return [stop(0, 0, 0.15, 0.35), stop(0.55, 0, 0.55, 0.75), stop(1, 0.65, 0.95, 0.9)]
        }
    }
}

/// A button showing the gradient in hand, opening its editor.
struct GradientWell: View {
    @Bindable var state: EditorState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Capsule()
                .fill(LinearGradient(stops: state.gradientStopsShown.swiftUIStops, startPoint: .leading, endPoint: .trailing))
                .background(Checkerboard(squareSize: 4).clipShape(.capsule))
                .overlay(Capsule().strokeBorder(.white, lineWidth: 2))
                .overlay(Capsule().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .frame(width: 48, height: 24)
                .frame(height: EditorToolbarMetrics.controlSize)
                .padding(.horizontal, 4)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gradient.Edit")
        .accessibilityIdentifier("gradientWell")
        .popover(isPresented: $isPresented) {
            GradientEditor(state: state)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The gradient's stops along a bar: tap one to pick it and change its
/// colour, drag it along, add stops between or take them away.
struct GradientEditor: View {
    @Bindable var state: EditorState
    @State private var selected = 0

    var body: some View {
        let stops = state.gradientStopsShown
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                ForEach(GradientPreset.allCases) { preset in
                    Button(preset.labelKey) { state.applyGradientPreset(preset) }
                        .accessibilityIdentifier("gradientPreset.\(preset.rawValue)")
                }
            } label: {
                Label("Gradient.Presets", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("gradientPresets")

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(stops: stops.swiftUIStops, startPoint: .leading, endPoint: .trailing))
                        .background(Checkerboard(squareSize: 6).clipShape(.rect(cornerRadius: 6)))
                        .frame(height: 28)
                        .contentShape(.rect)
                        .onTapGesture { location in
                            addStop(at: location.x / width)
                        }
                    ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                        StopKnob(color: stop.color, isSelected: index == selected)
                            .position(x: stop.location * width, y: 40)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                selected = index
                                moveStop(index, to: drag.location.x / width)
                            })
                            .accessibilityIdentifier("gradientStop.\(index)")
                    }
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 8)

            if stops.indices.contains(selected) {
                HStack {
                    ColorPicker("Gradient.StopColor", selection: Binding(
                        get: { stops[selected].color.color },
                        set: { value in setColor(RGBAColor(value), of: selected) }
                    ), supportsOpacity: true)
                    Spacer()
                    Button("Gradient.RemoveStop", systemImage: "trash", role: .destructive) {
                        removeStop(selected)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(stops.count <= 2)
                    .accessibilityIdentifier("removeGradientStop")
                }
                .font(.subheadline)
            }
            Text("Gradient.Footer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 300)
    }

    private func edit(_ change: (inout [PaintGradient.Stop]) -> Void) {
        var stops = state.gradientStopsShown
        change(&stops)
        state.gradientStops = stops
    }

    private func addStop(at location: Double) {
        let location = min(max(location, 0), 1)
        let gradient = PaintGradient(stops: state.gradientStopsShown)
        edit { stops in
            stops.append(PaintGradient.Stop(location: location, color: gradient.color(at: location)))
            stops.sort { $0.location < $1.location }
            selected = stops.firstIndex { $0.location == location } ?? 0
        }
    }

    private func moveStop(_ index: Int, to location: Double) {
        edit { stops in
            guard stops.indices.contains(index) else { return }
            stops[index].location = min(max(location, 0), 1)
        }
    }

    private func setColor(_ color: RGBAColor, of index: Int) {
        edit { stops in
            guard stops.indices.contains(index) else { return }
            stops[index].color = color
        }
    }

    private func removeStop(_ index: Int) {
        edit { stops in
            guard stops.count > 2, stops.indices.contains(index) else { return }
            stops.remove(at: index)
        }
        selected = max(0, selected - 1)
    }
}

/// A stop's handle under the gradient bar.
private struct StopKnob: View {
    let color: RGBAColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(color.withAlpha(1).color)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .black.opacity(0.25), lineWidth: isSelected ? 2 : 0.5).padding(-2))
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
            .contentShape(.circle)
    }
}

extension [PaintGradient.Stop] {
    var swiftUIStops: [Gradient.Stop] {
        sorted { $0.location < $1.location }.map { Gradient.Stop(color: $0.color.color, location: $0.location) }
    }
}

extension PaintGradient {
    /// The colour the gradient has at `location`, between its stops.
    func color(at location: Double) -> RGBAColor {
        let stops = sortedStops
        guard let after = stops.firstIndex(where: { $0.location >= location }) else { return stops.last!.color }
        guard after > 0 else { return stops[0].color }
        let a = stops[after - 1], b = stops[after]
        let t = b.location > a.location ? (location - a.location) / (b.location - a.location) : 0
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return RGBAColor(
            red: mix(a.color.red, b.color.red), green: mix(a.color.green, b.color.green),
            blue: mix(a.color.blue, b.color.blue), alpha: mix(a.color.alpha, b.color.alpha)
        )
    }
}

extension EditorState {
    /// The gradient's stops as the tool will paint them: chosen ones, or
    /// the brush colour fading out.
    var gradientStopsShown: [PaintGradient.Stop] {
        gradientStops ?? PaintGradient.fading(color).stops
    }

    func applyGradientPreset(_ preset: GradientPreset) {
        // The first follows the brush colour as it changes.
        gradientStops = preset == .fading ? nil : preset.stops(with: color)
    }
}
