import Paintbrush
import SwiftUI

/// The words and setting of the active text layer, applied as they change.
struct TextPanel: View {
    @Bindable var state: EditorState
    @FocusState private var isEditing: Bool
    @State private var isPickingFont = false
    @State private var selection: TextSelection?
    /// The characters picked for styling, kept while a control is used
    /// and the text field gives up its selection.
    @State private var pickedRange: NSRange?

    var body: some View {
        Form {
            if let text = state.activeLayer?.text {
                Section {
                    TextField("Text.Placeholder", text: Binding(
                        get: { text.string },
                        set: { value in
                            state.updateText { $0.setString(value) }
                        }
                    ), selection: $selection, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($isEditing)
                        .accessibilityIdentifier("textContent")
                        .onChange(of: selection) { _, selection in pick(selection, in: text.string) }
                } footer: {
                    if pickedRange == nil { Text("Text.Selection.Footer") }
                }
                if let range = pickedRange, NSMaxRange(range) <= text.string.utf16.count {
                    CharacterStyleSection(text: text, range: range, state: state) { pickedRange = nil }
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
        .panelFormStyle()
        // Characters picked on one layer are not the same ones on another.
        .onChange(of: state.activeLayerID) {
            selection = nil
            pickedRange = nil
        }
        .sheet(isPresented: $isPickingFont) {
            NavigationStack {
                FontPicker { family in
                    state.updateText { $0.fontName = family }
                    isPickingFont = false
                }
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .barLeading) {
                        Button("Text.Font.System") {
                            state.updateText { $0.fontName = nil }
                            isPickingFont = false
                        }
                    }
                    ToolbarItem(placement: .barTrailing) {
                        Button("Common.Cancel", role: .cancel) { isPickingFont = false }
                    }
                }
                .inlineNavigationTitle()
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

    /// Picks characters for styling when some are selected; a caret alone
    /// lets go of them.
    private func pick(_ selection: TextSelection?, in string: String) {
        guard let selection else { return }
        guard case .selection(let range) = selection.indices,
              range.lowerBound >= string.startIndex, range.upperBound <= string.endIndex else { return }
        pickedRange = range.isEmpty ? nil : NSRange(range, in: string)
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

/// Styling for the characters picked in the text, over the layer's own.
private struct CharacterStyleSection: View {
    let text: TextContent
    let range: NSRange
    let state: EditorState
    let done: () -> Void

    var body: some View {
        let style = text.style(in: range)
        Section {
            ColorPicker("Text.Color", selection: Binding(
                get: { (style.color ?? text.color).color },
                set: { value in restyle { $0.color = RGBAColor(value) } }
            ))
            HStack {
                Toggle("Text.Bold", systemImage: "bold", isOn: Binding(
                    get: { style.isBold ?? text.isBold }, set: { value in restyle { $0.isBold = value } }
                ))
                Toggle("Text.Italic", systemImage: "italic", isOn: Binding(
                    get: { style.isItalic ?? text.isItalic }, set: { value in restyle { $0.isItalic = value } }
                ))
                Toggle("Text.Underline", systemImage: "underline", isOn: Binding(
                    get: { style.isUnderlined ?? false }, set: { value in restyle { $0.isUnderlined = value ? true : nil } }
                ))
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            LabeledSlider(
                label: "Text.Size",
                value: Binding(
                    get: { log2(style.sizeScale ?? 1) },
                    set: { value in restyle { $0.sizeScale = abs(value) < 0.02 ? nil : pow(2, value) } }
                ),
                range: -2...2,
                valueText: "\(Int(((style.sizeScale ?? 1) * 100).rounded()))%"
            )
            LabeledSlider(
                label: "Text.Selection.Kerning",
                value: Binding(
                    get: { style.kerning ?? 0 },
                    set: { value in restyle { $0.kerning = abs(value) < 0.005 ? nil : value } }
                ),
                range: -0.3...1,
                valueText: "\(Int(((style.kerning ?? 0) * 1000).rounded()))"
            )
            .accessibilityIdentifier("characterKerning")
            LabeledSlider(
                label: "Text.Selection.Baseline",
                value: Binding(
                    get: { style.baselineShift ?? 0 },
                    set: { value in restyle { $0.baselineShift = abs(value) < 0.01 ? nil : value } }
                ),
                range: -1...1,
                valueText: "\(Int(((style.baselineShift ?? 0) * text.fontSize).rounded())) px"
            )
            Button("Text.Selection.Clear", systemImage: "eraser") {
                state.updateText { $0.clearStyle(range) }
            }
        } header: {
            HStack {
                Text("Text.Selection")
                Spacer()
                Button("Common.Done", action: done)
                    .font(.footnote)
            }
        }
        .accessibilityIdentifier("characterStyle")
    }

    private func restyle(_ change: @escaping (inout TextRun.Style) -> Void) {
        state.updateText { $0.restyle(range, change) }
    }
}

