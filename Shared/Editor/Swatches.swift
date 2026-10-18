import Paintbrush
import SwiftUI

/// The Human Interface Guidelines system colours, offered as swatches, as
/// Tables offers them: paintings made from the platform palette look as if
/// they belong on it. The colour picker is still there for anything else.
enum SystemPalette {
    struct Swatch: Identifiable, Hashable, Sendable {
        let id: String
        /// String catalog key for the colour's name, spoken by VoiceOver.
        let labelKey: String
        let color: RGBAColor

        var label: LocalizedStringKey { LocalizedStringKey(labelKey) }
    }

    private static func rgb(_ hex: UInt32) -> RGBAColor {
        RGBAColor(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255
        )
    }

    static let all: [Swatch] = [
        Swatch(id: "red", labelKey: "Color.Red", color: rgb(0xFF3B30)),
        Swatch(id: "orange", labelKey: "Color.Orange", color: rgb(0xFF9500)),
        Swatch(id: "yellow", labelKey: "Color.Yellow", color: rgb(0xFFCC00)),
        Swatch(id: "green", labelKey: "Color.Green", color: rgb(0x34C759)),
        Swatch(id: "mint", labelKey: "Color.Mint", color: rgb(0x00C7BE)),
        Swatch(id: "teal", labelKey: "Color.Teal", color: rgb(0x30B0C7)),
        Swatch(id: "cyan", labelKey: "Color.Cyan", color: rgb(0x32ADE6)),
        Swatch(id: "blue", labelKey: "Color.Blue", color: rgb(0x007AFF)),
        Swatch(id: "indigo", labelKey: "Color.Indigo", color: rgb(0x5856D6)),
        Swatch(id: "purple", labelKey: "Color.Purple", color: rgb(0xAF52DE)),
        Swatch(id: "pink", labelKey: "Color.Pink", color: rgb(0xFF2D55)),
        Swatch(id: "brown", labelKey: "Color.Brown", color: rgb(0xA2845E)),
        Swatch(id: "black", labelKey: "Color.Black", color: rgb(0x000000)),
        Swatch(id: "gray", labelKey: "Color.Grey", color: rgb(0x8E8E93)),
        Swatch(id: "gray3", labelKey: "Color.Grey3", color: rgb(0xC7C7CC)),
        Swatch(id: "white", labelKey: "Color.White", color: rgb(0xFFFFFF)),
    ]
}

extension EditorState {
    /// Keeps `color` among the picture's swatches, unless it is there.
    func addSwatch(_ color: RGBAColor) {
        let color = color.withAlpha(1)
        guard !composition.swatches.contains(color) else { return }
        update { $0.swatches.append(color) }
    }

    func removeSwatch(at index: Int) {
        guard composition.swatches.indices.contains(index) else { return }
        update { _ = $0.swatches.remove(at: index) }
    }
}

/// The colour in use. Opens the picture's swatches, the system palette and
/// the colour picker.
struct ColorWell: View {
    @Bindable var state: EditorState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Circle()
                .fill(state.color.color)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .frame(width: 28, height: 28)
                .frame(width: EditorToolbarMetrics.controlSize, height: EditorToolbarMetrics.controlSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Options.Color")
        .accessibilityValue(state.color.hexString)
        .accessibilityIdentifier("colorWell")
        .help(Text("Options.Color"))
        .popover(isPresented: $isPresented) {
            SwatchPicker(state: state)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SwatchPicker: View {
    @Bindable var state: EditorState
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Swatches.Document").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(state.composition.swatches.enumerated()), id: \.offset) { index, color in
                    swatch(color, label: Text(verbatim: color.hexString))
                        .contextMenu {
                            Button("Swatches.Remove", systemImage: "trash", role: .destructive) {
                                state.removeSwatch(at: index)
                            }
                        }
                }
                Button {
                    state.addSwatch(state.color)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swatches.Add")
                .accessibilityIdentifier("addSwatch")
            }
            Text("Swatches.System").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(SystemPalette.all) { swatch in
                    self.swatch(swatch.color, label: Text(swatch.label))
                }
            }
            ColorPicker(
                "Swatches.MoreColors",
                selection: Binding(get: { state.color.color }, set: { state.color = RGBAColor($0) }),
                supportsOpacity: false
            )
            .font(.subheadline)
        }
        .padding(16)
        .frame(width: 8 * 32 + 7 * 8 + 32)
    }

    private func swatch(_ color: RGBAColor, label: Text) -> some View {
        let isChosen = state.color.withAlpha(1) == color.withAlpha(1)
        return Button {
            state.color = color
        } label: {
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .padding(isChosen ? 3 : 0)
                .overlay(Circle().strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
