import Paintbrush
import SwiftUI

/// A new size for the canvas, and what becomes of the picture on it: kept as
/// it is and placed by an anchor, scaled evenly to fit, or stretched to fill.
struct CanvasSizePanel: View {
    @Bindable var state: EditorState

    @State private var width = 0
    @State private var height = 0
    @State private var keepsProportions = true
    @State private var mode: Composition.CanvasResize = .anchor
    @State private var anchor = CGPoint(x: 0.5, y: 0.5)
    @State private var thumbnail: CGImage?

    private var original: CGSize { state.composition.size }
    private var newSize: CGSize { CGSize(width: width, height: height) }

    var body: some View {
        Form {
            Section {
                CanvasResizeDiagram(
                    original: original, newSize: newSize, mode: mode, anchor: anchor, thumbnail: thumbnail
                )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                dimensionField("ImageSize.Width", value: $width) { newWidth in
                    if keepsProportions { height = max(1, Int((Double(newWidth) * original.height / original.width).rounded())) }
                }
                .accessibilityIdentifier("imageWidth")
                dimensionField("ImageSize.Height", value: $height) { newHeight in
                    if keepsProportions { width = max(1, Int((Double(newHeight) * original.width / original.height).rounded())) }
                }
                .accessibilityIdentifier("imageHeight")
                Toggle("ImageSize.KeepProportions", isOn: $keepsProportions)
                HStack {
                    ForEach([50, 100, 200], id: \.self) { percent in
                        Button(percent.formatted(.percent)) {
                            width = max(1, Int(original.width) * percent / 100)
                            height = max(1, Int(original.height) * percent / 100)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
            } footer: {
                Text("ImageSize.Original \(Int(original.width)) \(Int(original.height))")
            }

            Section {
                Picker("CanvasSize.Picture", selection: $mode) {
                    ForEach(Composition.CanvasResize.allCases) { mode in
                        Label(Self.label(for: mode), systemImage: Self.symbol(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("canvasResizeMode")
            } header: {
                Text("CanvasSize.Picture")
            } footer: {
                Text(Self.footer(for: mode))
            }

            if mode.usesAnchor {
                Section("ImageSize.Anchor") {
                    AnchorPicker(anchor: $anchor)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy(duration: 0.25), value: mode)
        .onAppear {
            width = Int(original.width)
            height = Int(original.height)
        }
        .task {
            let composition = state.composition
            thumbnail = await Task.detached(priority: .userInitiated) {
                CompositionRenderer.thumbnail(composition, maxPixelSize: 400)
            }.value
        }
        .panelActions(
            cancel: { state.presentedPanel = nil },
            confirm: {
                if newSize != original {
                    state.resizeCanvas(to: newSize, mode: mode, anchor: anchor)
                }
                state.presentedPanel = nil
            },
            confirmDisabled: !isValid,
            confirmIdentifier: "applyImageSize"
        )
    }

    private var isValid: Bool {
        (1...Bitmap.maximumDimension).contains(width) && (1...Bitmap.maximumDimension).contains(height)
    }

    private static func label(for mode: Composition.CanvasResize) -> LocalizedStringKey {
        switch mode {
        case .anchor: return "CanvasSize.Mode.Anchor"
        case .proportional: return "CanvasSize.Mode.Proportional"
        case .stretch: return "CanvasSize.Mode.Stretch"
        }
    }

    private static func symbol(for mode: Composition.CanvasResize) -> String {
        switch mode {
        case .anchor: return "arrow.down.right.and.arrow.up.left.square"
        case .proportional: return "aspectratio"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    private static func footer(for mode: Composition.CanvasResize) -> LocalizedStringKey {
        switch mode {
        case .anchor: return "CanvasSize.Mode.Anchor.Footer"
        case .proportional: return "CanvasSize.Mode.Proportional.Footer"
        case .stretch: return "CanvasSize.Mode.Stretch.Footer"
        }
    }

    private func dimensionField(
        _ label: LocalizedStringKey, value: Binding<Int>, onEdit: @escaping (Int) -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        value.wrappedValue = newValue
                        onEdit(newValue)
                    }
                ), format: .number.grouping(.never))
                .numberKeyboard(.integer)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                Text("ImageSize.Pixels")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The new canvas drawn to scale with the old picture placed on it, so the
/// result can be seen before it is applied.
private struct CanvasResizeDiagram: View {
    let original: CGSize
    let newSize: CGSize
    let mode: Composition.CanvasResize
    let anchor: CGPoint
    var thumbnail: CGImage?

    var body: some View {
        Canvas { context, size in
            guard original.width > 0, original.height > 0, newSize.width > 0, newSize.height > 0 else { return }
            let picture = CGRect(origin: .zero, size: original)
                .applying(EditorState.canvasMapping(from: original, to: newSize, mode: mode, anchor: anchor))
            // Fit both the new canvas and the picture, which may hang off it.
            let bounds = picture.union(CGRect(origin: .zero, size: newSize))
            let scale = min((size.width - 8) / bounds.width, (size.height - 8) / bounds.height)
            let origin = CGPoint(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale
            )
            func place(_ rect: CGRect) -> CGRect {
                CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
                       width: rect.width * scale, height: rect.height * scale)
            }
            let canvas = place(CGRect(origin: .zero, size: newSize))
            let placed = place(picture)
            context.fill(Path(canvas), with: .color(.white))
            // The picture drawn faintly in full, so a part that will be
            // cropped off still shows, then solidly where the canvas keeps it.
            if let thumbnail {
                let image = Image(decorative: thumbnail, scale: 1)
                var faint = context
                faint.opacity = 0.3
                faint.draw(image, in: placed)
                var kept = context
                kept.clip(to: Path(canvas))
                kept.draw(image, in: placed)
            } else {
                context.fill(Path(placed), with: .color(.accentColor.opacity(0.35)))
            }
            context.stroke(Path(canvas), with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
            context.stroke(
                Path(placed), with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }
        .accessibilityHidden(true)
    }
}

/// Nine squares for where the picture sits when it does not fill the canvas.
struct AnchorPicker: View {
    @Binding var anchor: CGPoint

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { y in
                GridRow {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { x in
                        let isSelected = anchor == CGPoint(x: x, y: y)
                        Button {
                            anchor = CGPoint(x: x, y: y)
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if isSelected {
                                        Image(systemName: "photo")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("ImageSize.Anchor")
                        .accessibilityValue(Text(verbatim: "\(Int(x * 2)), \(Int(y * 2))"))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("anchor.\(Int(x * 2)).\(Int(y * 2))")
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
