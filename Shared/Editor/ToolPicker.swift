import SwiftUI

/// Matches the standard navigation toolbar's control size.
enum EditorToolbarMetrics {
    static let controlSize: CGFloat = 44
    static let rowHeight: CGFloat = 60
}

/// The tools, as a Liquid Glass carousel along the bottom of an iPhone and
/// a rail down the side of an iPad. Grouped the same way in both: arranging,
/// painting, adding, then the panels that change the whole layer.
struct ToolPicker: View {
    enum Layout {
        /// A sideways-scrolling carousel within thumb reach.
        case carousel
        /// A column beside the canvas.
        case rail
    }

    let layout: Layout
    @Bindable var state: EditorState
    /// Lets the panels these buttons open zoom out of them.
    var namespace: Namespace.ID

    private static let panels: [EditorPanel] = [.adjustments, .filters, .looks, .history]

    var body: some View {
        switch layout {
        case .carousel:
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) { groups }
                            .padding(.horizontal, 12)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollClipDisabled()
                // A tool picked by keyboard or by Apple Pencil is brought
                // into view rather than left to be found.
                .onChange(of: state.tool) { _, tool in
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(tool, anchor: .center) }
                }
            }
            .frame(height: EditorToolbarMetrics.rowHeight)
        case .rail:
            // Centred beside the canvas while it fits; on a short window it
            // scrolls instead of running under the toolbar.
            let rail = GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) { groups }
                    .padding(.vertical, 12)
            }
            ViewThatFits(in: .vertical) {
                rail
                ScrollView(.vertical) { rail }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
            }
            .frame(width: EditorToolbarMetrics.rowHeight)
        }
    }

    @ViewBuilder
    private var groups: some View {
        ForEach(Tool.groups, id: \.self) { tools in
            GlassGroup(axis: layout == .rail ? .vertical : .horizontal) {
                ForEach(tools) { tool in
                    GlassIconButton(symbol: tool.symbolName, label: tool.label, isOn: state.tool == tool) {
                        state.tool = tool
                    }
                    .modifier(ToolShortcut(key: tool.shortcut, isEnabled: state.presentedPanel != .text))
                    .id(tool)
                    .accessibilityIdentifier("tool.\(tool.rawValue)")
                }
            }
        }
        GlassGroup(axis: layout == .rail ? .vertical : .horizontal) {
            ForEach(Self.panels) { panel in
                GlassIconButton(
                    symbol: panel.symbolName, label: panel.title, isOn: state.presentedPanel == panel
                ) {
                    state.presentedPanel = panel
                }
                .disabled(state.activeLayer == nil)
                .matchedTransitionSource(id: panel, in: namespace)
                .accessibilityIdentifier("panel.\(panel.rawValue)")
            }
        }
    }
}

/// Single keys pick tools from a hardware keyboard, as on the desktop —
/// except while text is being typed, when the keys are the text's.
private struct ToolShortcut: ViewModifier {
    let key: KeyEquivalent
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut(key, modifiers: [])
        } else {
            content
        }
    }
}

/// A capsule of Liquid Glass holding a few related buttons.
struct GlassGroup<Content: View>: View {
    var axis: Axis = .horizontal
    var scrollsHorizontally = false
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            if axis == .horizontal {
                if scrollsHorizontally {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { ForEach(subviews) { $0 } }
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) { ForEach(subviews) { $0 } }
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: EditorToolbarMetrics.controlSize)
                    }
                    .frame(minWidth: EditorToolbarMetrics.controlSize)
                } else {
                    HStack(spacing: 8) { ForEach(subviews) { $0 } }
                }
            } else {
                VStack(spacing: 8) { ForEach(subviews) { $0 } }
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A round icon button for the glass bars. When on, it reads as a lit key.
struct GlassIconButton: View {
    let symbol: String
    let label: Text
    var isOn = false
    let action: () -> Void

    init(symbol: String, label: LocalizedStringKey, isOn: Bool = false, action: @escaping () -> Void) {
        self.init(symbol: symbol, label: Text(label), isOn: isOn, action: action)
    }

    /// For names already looked up, such as a shape's.
    init(symbol: String, title: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.init(symbol: symbol, label: Text(verbatim: title), isOn: isOn, action: action)
    }

    init(symbol: String, label: Text, isOn: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: EditorToolbarMetrics.controlSize, height: EditorToolbarMetrics.controlSize)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A menu dressed as a glass bar button.
struct GlassMenuButton<Content: View>: View {
    let symbol: String
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: EditorToolbarMetrics.controlSize, height: EditorToolbarMetrics.controlSize)
                .foregroundStyle(Color.primary)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
