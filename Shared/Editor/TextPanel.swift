import SwiftUI

/// The words and setting of the active text layer, applied as they change.
struct TextPanel: View {
    @Bindable var state: EditorState
    @FocusState private var isEditing: Bool
    @State private var isPickingFont = false

    var body: some View {
        Form {
            if let text = state.activeLayer?.text {
                Section {
                    TextField("Text.Placeholder", text: binding(\.string), axis: .vertical)
                        .lineLimit(1...6)
                        .focused($isEditing)
                        .accessibilityIdentifier("textContent")
                }
                Section {
                    Button {
                        isPickingFont = true
                    } label: {
                        LabeledContent("Text.Font") {
                            Text(text.fontName ?? String(localized: "Text.Font.System"))
                                .font(text.fontName.map { .custom($0, size: 17) } ?? .body)
                        }
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("textFont")
                    if text.fontName == nil {
                        Picker("Text.Design", selection: binding(\.design)) {
                            ForEach(TextContent.Design.allCases) { design in
                                Text(design.label).tag(design)
                            }
                        }
                    }
                    HStack {
                        Toggle("Text.Bold", systemImage: "bold", isOn: binding(\.isBold))
                        Toggle("Text.Italic", systemImage: "italic", isOn: binding(\.isItalic))
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    Picker("Text.Alignment", selection: binding(\.alignment)) {
                        ForEach(TextContent.Alignment.allCases) { alignment in
                            Label(alignment.label, systemImage: alignment.symbolName).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(
                        label: "Text.Size",
                        value: Binding(
                            get: { BrushSizeScale.position(for: min(text.fontSize, BrushSettings.sizeRange.upperBound)) },
                            set: { value in state.updateText { $0.fontSize = max(4, BrushSizeScale.size(at: value)) } }
                        ),
                        valueText: "\(Int(text.fontSize.rounded())) px"
                    )
                    LabeledSlider(
                        label: "Text.Tracking",
                        value: Binding(
                            get: { text.tracking ?? 0 },
                            set: { value in state.updateText { $0.tracking = abs(value) < 0.005 ? nil : value } }
                        ),
                        range: -0.2...1,
                        valueText: "\(Int(((text.tracking ?? 0) * 1000).rounded()))"
                    )
                    .accessibilityIdentifier("textTracking")
                    LabeledSlider(
                        label: "Text.LineSpacing",
                        value: Binding(
                            get: { text.lineSpacing ?? 1 },
                            set: { value in state.updateText { $0.lineSpacing = abs(value - 1) < 0.01 ? nil : value } }
                        ),
                        range: 0.6...3,
                        valueText: String(format: "%.2f×", text.lineSpacing ?? 1)
                    )
                    .accessibilityIdentifier("textLineSpacing")
                    Toggle("Text.Kerning", isOn: Binding(
                        get: { text.usesKerning ?? true },
                        set: { value in state.updateText { $0.usesKerning = value ? nil : false } }
                    ))
                    ColorPicker(
                        "Text.Color",
                        selection: Binding(
                            get: { text.color.color },
                            set: { value in state.updateText { $0.color = RGBAColor(value) } }
                        )
                    )
                }
                Section {
                    Toggle("Text.Box", isOn: Binding(
                        get: { text.boxWidth != nil },
                        set: { isOn in
                            let start = (TextRenderer.attributedString(for: text).size().width).rounded()
                            state.updateText { $0.boxWidth = isOn ? max(start, text.fontSize * 4) : nil }
                        }
                    ))
                    .accessibilityIdentifier("textBox")
                    if let boxWidth = text.boxWidth {
                        LabeledSlider(
                            label: "Text.Box.Width",
                            value: Binding(
                                get: { boxWidth },
                                set: { value in state.updateText { $0.boxWidth = value.rounded() } }
                            ),
                            range: max(text.fontSize, 10)...max(state.composition.size.width * 1.5, text.fontSize * 2),
                            valueText: "\(Int(boxWidth.rounded())) px"
                        )
                        .accessibilityIdentifier("textBoxWidth")
                    }
                } footer: {
                    Text("Text.Box.Footer")
                }
                Section("Text.Outline") {
                    Toggle("Text.Outline.Show", isOn: Binding(
                        get: { text.outline != nil },
                        set: { isOn in
                            state.updateText { $0.outline = isOn ? TextContent.Outline(color: Self.contrasting(text.color)) : nil }
                        }
                    ))
                    .accessibilityIdentifier("textOutline")
                    if let outline = text.outline {
                        ColorPicker("Text.Color", selection: Binding(
                            get: { outline.color.color },
                            set: { value in state.updateText { $0.outline?.color = RGBAColor(value) } }
                        ))
                        LabeledSlider(
                            label: "Text.Outline.Width",
                            value: Binding(
                                get: { outline.width },
                                set: { value in state.updateText { $0.outline?.width = value } }
                            ),
                            range: 0.01...0.3,
                            valueText: "\(Int((outline.width * text.fontSize).rounded())) px"
                        )
                    }
                }
                Section("Text.Background") {
                    Toggle("Text.Background.Show", isOn: Binding(
                        get: { text.background != nil },
                        set: { isOn in
                            state.updateText {
                                $0.background = isOn ? TextContent.Background(color: Self.contrasting(text.color)) : nil
                            }
                        }
                    ))
                    .accessibilityIdentifier("textBackground")
                    if let background = text.background {
                        ColorPicker("Text.Color", selection: Binding(
                            get: { background.color.color },
                            set: { value in state.updateText { $0.background?.color = RGBAColor(value) } }
                        ))
                        LabeledSlider(
                            label: "Text.Background.Padding",
                            value: Binding(
                                get: { background.padding },
                                set: { value in state.updateText { $0.background?.padding = value } }
                            ),
                            valueText: "\(Int((background.padding * text.fontSize).rounded())) px"
                        )
                        LabeledSlider(
                            label: "Text.Background.Corners",
                            value: Binding(
                                get: { background.cornerRadius },
                                set: { value in state.updateText { $0.background?.cornerRadius = value } }
                            ),
                            valueText: "\(Int((background.cornerRadius * 100).rounded()))%"
                        )
                    }
                }
            } else {
                ContentUnavailableView("Text.NoTextLayer", systemImage: "textformat", description: Text("Text.NoTextLayer.Detail"))
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPickingFont) {
            NavigationStack {
                FontPicker { family in
                    state.updateText { $0.fontName = family }
                    isPickingFont = false
                }
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Text.Font.System") {
                            state.updateText { $0.fontName = nil }
                            isPickingFont = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Common.Cancel", role: .cancel) { isPickingFont = false }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            // A new text layer starts with placeholder words, which give way
            // to whatever is typed.
            if state.activeLayer?.text?.string == String(localized: "Text.Placeholder") {
                state.updateText { $0.string = "" }
                isEditing = true
            }
        }
        .onDisappear {
            // Nothing typed: the layer it would have been is not kept.
            if let layer = state.activeLayer, layer.text?.string.isEmpty == true {
                state.deleteLayer(layer.id)
            }
        }
        .panelActions(confirm: { state.presentedPanel = nil })
    }

    /// Black or white, whichever stands out against the text's colour, as a
    /// starting point for an outline or background.
    private static func contrasting(_ color: RGBAColor) -> RGBAColor {
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.5 ? .black : .white
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TextContent, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { state.activeLayer?.text?[keyPath: keyPath] ?? TextContent(string: "", fontSize: 1, color: .black)[keyPath: keyPath] },
            set: { value in state.updateText { $0[keyPath: keyPath] = value } }
        )
    }
}
