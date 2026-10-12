import SwiftUI
import UniformTypeIdentifiers

/// The editor: the canvas, the tools over it, and the panels beside it.
///
/// On iPhone the tools are a carousel along the bottom, with the settings
/// of the tool in hand just above it, and panels rise as sheets. On iPad the
/// tools are a rail down the side and panels live in an inspector.
///
/// Hosts — a document window, a photo opened from the library, the Photos
/// editing extension — supply the picture and add their own toolbar items.
/// A host's own action, such as sharing, goes in `actions`, grouped with the
/// "…" menu.
struct EditorView<Actions: View>: View {
    @Binding var composition: Composition
    private let actions: Actions
    @State private var state = EditorState()
    @State private var history = CompositionHistory()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Namespace private var panelTransition
    /// The height of the panel sheet on iPhone. Set afresh for each panel:
    /// one panel opening from another would otherwise keep its height.
    @State private var panelDetent: PresentationDetent = .medium
    @State private var bottomToolbarInset: CGFloat = 0

    init(composition: Binding<Composition>, @ViewBuilder actions: () -> Actions) {
        _composition = composition
        self.actions = actions()
    }

    private var isCompact: Bool { horizontalSizeClass != .regular }

    var body: some View {
        // While comparing, the picture as it was opened, untouchable.
        CanvasView(
            composition: state.isComparing ? history.original ?? state.composition : state.composition,
            state: state, history: history
        )
        .allowsHitTesting(!state.isComparing)
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
            .background { KeyboardCommands(state: state) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCompact {
                    VStack(spacing: 8) {
                        HStack(spacing: 0) {
                            ToolOptionsBar(state: state)
                            layersButton
                                .padding(.trailing, 12)
                        }
                        ToolPicker(layout: .carousel, state: state, namespace: panelTransition)
                    }
                    .padding(.bottom, 8 + bottomToolbarInset)
                } else {
                    ToolOptionsBar(state: state)
                        .padding(.leading, 72)
                        .padding(.bottom, 12 + bottomToolbarInset)
                }
            }
            .background {
                EditorBottomSafeAreaReader { bottomToolbarInset = $0 }
            }
            .overlay(alignment: .leading) {
                if !isCompact {
                    ToolPicker(layout: .rail, state: state, namespace: panelTransition)
                        .padding(.leading, 12)
                }
            }
            .overlay(alignment: .top) { statusBar }
            .onChange(of: isCompact, initial: true) { _, _ in updateInsets() }
            .onChange(of: state.presentedPanel) { _, panel in
                panelDetent = panel?.keepsCanvasVisible == false ? .large : .medium
                updateInsets()
                if !isCompact, panel != nil { state.isInspectorPresented = true }
            }
            .animation(.snappy(duration: 0.3), value: state.canvasInsets)
            .modifier(InspectorPresentation(isEnabled: !isCompact, isPresented: $state.isInspectorPresented) {
                let panel = state.presentedPanel ?? .layers
                panelContent(panel)
                    .environment(\.panelPlacement, .inspector)
                    .environment(\.panelTitle, panel.title)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            })
            .sheet(item: Binding(
                get: { isCompact ? state.presentedPanel : nil },
                set: { state.presentedPanel = $0 }
            )) { panel in
                NavigationStack {
                    panelContent(panel)
                        .navigationTitle(panel.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationBarBackButtonHidden()
                }
                .navigationTransition(.zoom(sourceID: panel, in: panelTransition))
                .presentationDetents(panel.keepsCanvasVisible ? [.medium, .large] : [.large], selection: $panelDetent)
                // Undimmed, so the picture the panel is changing can be seen.
                .presentationBackgroundInteraction(panel.keepsCanvasVisible ? .enabled(upThrough: .medium) : .disabled)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationBackground(.regularMaterial)
                // A sheet covers the editor, so what goes wrong in a panel
                // is told from the panel.
                .errorAlert(state, isActive: true)
            }
            .toolbar { editingToolbar }
            .fileImporter(
                isPresented: $state.isImportingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    let loaded = await ImageImport.load(urls)
                    state.addImageLayers(loaded.images)
                    if loaded.failed { state.errorMessage = String(localized: "Error.ImportFailed") }
                }
            }
            .dropDestination(for: DroppedImage.self) { items, _ in
                Task { state.addImageLayers(await ImageImport.load(items)) }
                return true
            }
            .onPencilDoubleTap { _ in
                state.tool = state.tool == .eraser ? .brush : .eraser
            }
            .sensoryFeedback(.selection, trigger: state.tool)
            .errorAlert(state, isActive: !isCompact || state.presentedPanel == nil)
            .selectionEditAlert(state)
            .onAppear(perform: attach)
            .onChange(of: composition) { _, new in state.sync(new) }
            #if DEBUG
            .modifier(ScreenshotFocus(state: state))
            #endif
    }

    private func attach() {
        let binding = $composition
        state.attach(to: composition) { binding.wrappedValue = $0 }
        let state = state
        let history = history
        state.edited = { history.record(from: $0, to: $1, tool: state.tool) }
        // Always the editor's own undo manager; see `CompositionHistory`.
        history.attach(
            to: nil,
            read: { state.read() },
            write: { state.write($0) },
            restored: { state.showRestored($0) }
        )
    }

    /// Room kept clear for the bars over the canvas, so a fitted picture is
    /// never under them; on iPhone, a half-height panel takes the bottom half.
    private func updateInsets() {
        if isCompact {
            let panelIsUp = state.presentedPanel?.keepsCanvasVisible == true
            let bottom = panelIsUp ? state.viewportSize.height * 0.5 : 0
            state.canvasInsets = EdgeInsets(top: 8, leading: 0, bottom: bottom, trailing: 0)
        } else {
            state.canvasInsets = EdgeInsets(top: 8, leading: 72, bottom: 0, trailing: 0)
        }
    }

    // MARK: - Pieces

    private var layersButton: some View {
        GlassEffectContainer {
            GlassGroup {
                GlassIconButton(
                    symbol: EditorPanel.layers.symbolName, label: EditorPanel.layers.title,
                    isOn: state.presentedPanel == .layers
                ) {
                    state.presentedPanel = .layers
                }
            }
        }
        .matchedTransitionSource(id: EditorPanel.layers, in: panelTransition)
        .accessibilityIdentifier("panel.layers")
    }

    /// The zoom level, and a spinner while edits are being worked on.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if state.zoom != 1 || state.pan != .zero || state.rotation != 0 {
                Button {
                    withAnimation(.snappy) { state.fitCanvas() }
                } label: {
                    Text(verbatim: "\(Int((state.viewport.scale * displayScale * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel("Canvas.FitToScreen")
                .accessibilityIdentifier("zoomLevel")
            }
            if state.editsMask, state.activeLayer?.isAdjustment != true {
                Button {
                    state.isEditingMask = false
                } label: {
                    Label("Mask.Editing", systemImage: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor.opacity(0.3)).interactive(), in: .capsule)
                .accessibilityIdentifier("stopEditingMask")
            }
            if state.isBusy {
                ProgressView()
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
            }
        }
        .padding(.top, 8)
        .animation(.snappy(duration: 0.2), value: state.isBusy)
        .animation(.snappy(duration: 0.2), value: state.editsMask)
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .layers: LayersPanel(composition: state.composition, state: state)
        case .adjustments: AdjustmentsPanel(state: state)
        case .filters: LayerFiltersPanel(state: state)
        case .effects: LayerEffectsPanel(state: state)
        case .looks: LooksPanel(state: state)
        case .text: TextPanel(state: state)
        case .imageSize: CanvasSizePanel(state: state)
        case .history: HistoryPanel(history: history, state: state)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editingToolbar: some ToolbarContent {
        // On iPad the clipboard sits out in the bar, ahead of Undo and Redo;
        // on iPhone there is no room, and it is in the "…" menu instead.
        if !isCompact {
            ToolbarItemGroup(placement: .topBarTrailing) { clipboardButtons }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        // Pinned to the trailing edge: as primary actions the bar would fold
        // Redo into the "…" menu once it ran short of room.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo")
            Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
                .disabled(!history.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityIdentifier("redo")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        // On iPhone the bar has no room for the host's action beside the
        // menu, and would fold both into a menu of its own; inside the "…"
        // menu, the action is one tap away instead of two.
        if isCompact {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu {
                    Section { actions }
                    Section { clipboardButtons }
                }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                actions
                moreMenu()
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Toolbar.Inspector", systemImage: "sidebar.trailing") {
                    state.isInspectorPresented.toggle()
                }
                .accessibilityIdentifier("toggleInspector")
            }
        }
    }

    /// A menu of its own rather than secondary actions, which iPad would
    /// spread across the bar. The layer actions live with the layers, in
    /// their panel.
    private func moreMenu(@ViewBuilder leading: () -> some View = { EmptyView() }) -> some View {
        Menu {
            leading()
            Section {
                Button("Canvas.ImageSize", systemImage: EditorPanel.imageSize.symbolName) {
                    state.presentedPanel = .imageSize
                }
                Button("Canvas.RotateLeft", systemImage: "rotate.left") { state.rotateCanvas(clockwise: false) }
                Button("Canvas.RotateRight", systemImage: "rotate.right") { state.rotateCanvas(clockwise: true) }
                Button("Canvas.FlipHorizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    state.flipCanvas(horizontal: true)
                }
                Button("Canvas.FlipVertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    state.flipCanvas(horizontal: false)
                }
            }
            Section {
                Button("Select.All", systemImage: "selection.pin.in.out") { state.selectAll() }
                Button("Select.Deselect", systemImage: "xmark.square") { state.deselect() }
                    .disabled(state.selection == nil)
                Button("Select.Invert", systemImage: "square.on.square.intersection.dashed") { state.invertSelection() }
                    .disabled(state.selection == nil)
            }
            Section {
                Button("Canvas.FitToScreen", systemImage: "arrow.down.right.and.arrow.up.left") {
                    withAnimation(.snappy) { state.fitCanvas() }
                }
                Button("Canvas.ActualSize", systemImage: "1.magnifyingglass") {
                    withAnimation(.snappy) { state.zoomToActualSize(displayScale: displayScale) }
                }
                Toggle(
                    "Canvas.RotateWithGestures", systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    isOn: Binding(
                        get: { state.rotatesWithGestures },
                        set: { isOn in withAnimation(.snappy) { state.rotatesWithGestures = isOn } }
                    )
                )
            }
            Section {
                Toggle("Canvas.ShowRulers", systemImage: "ruler", isOn: $state.showsRulers)
                Button("Canvas.ClearGuides", systemImage: "xmark.square.fill") { state.clearGuides() }
                    .disabled(composition.guides.isEmpty)
            }
        } label: {
            Label("Toolbar.More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("more")
    }

    @ViewBuilder
    private var clipboardButtons: some View {
        Button("Edit.Cut", systemImage: "scissors") { state.cutToClipboard() }
            .disabled(state.selection == nil)
        Button("Edit.Copy", systemImage: "doc.on.doc") { state.copyToClipboard() }
            .disabled(state.activeLayer == nil)
        Button("Edit.Paste", systemImage: "doc.on.clipboard") { state.pasteFromClipboard() }
    }
}

extension EditorView where Actions == EmptyView {
    init(composition: Binding<Composition>) {
        self.init(composition: composition) { EmptyView() }
    }
}

#if DEBUG
/// For the App Store screenshots: launched with `-ScreenshotFocus "zoom x y"`,
/// x and y as fractions of the canvas, the editor frames that point at that
/// zoom, and again whenever the view changes, such as when a panel comes up.
private struct ScreenshotFocus: ViewModifier {
    let state: EditorState

    private static let focus: (zoom: Double, x: Double, y: Double)? = {
        let parts = UserDefaults.standard.string(forKey: "ScreenshotFocus")?.split(separator: " ").compactMap { Double($0) }
        guard let parts, parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }()

    func body(content: Content) -> some View {
        if let focus = Self.focus {
            content.onChange(of: state.viewport, initial: true) {
                let size = state.viewport.canvasSize
                state.focus(on: CGPoint(x: focus.x * size.width, y: focus.y * size.height), zoom: focus.zoom)
            }
        } else {
            content
        }
    }
}
#endif

/// The inspector beside the canvas, only where there is room for one. On
/// iPhone the panels are sheets, and an inspector there — even a closed one —
/// would compete with them for the window.
private struct InspectorPresentation<Inspector: View>: ViewModifier {
    let isEnabled: Bool
    @Binding var isPresented: Bool
    @ViewBuilder var inspector: Inspector

    func body(content: Content) -> some View {
        if isEnabled {
            content.inspector(isPresented: $isPresented) { inspector }
        } else {
            content
        }
    }
}

extension View {
    /// What went wrong, if anything, shown from this view while `isActive`.
    func errorAlert(_ state: EditorState, isActive: Bool) -> some View {
        alert(
            "Alert.Error.Title",
            isPresented: Binding(
                get: { isActive && state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("Common.OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

/// The document host can extend past the window's bottom safe area even
/// when SwiftUI reports a smaller inset. Measure that overlap in the
/// editor's own window, including when embedded in the Photos extension.
private struct EditorBottomSafeAreaReader: UIViewRepresentable {
    let insetChanged: (CGFloat) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.insetChanged = insetChanged
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.insetChanged = insetChanged
        view.setNeedsLayout()
    }

    final class ObserverView: UIView {
        var insetChanged: ((CGFloat) -> Void)?
        private var lastInset: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let frameInWindow = convert(bounds, to: window)
            let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
            let inset = max(0, frameInWindow.maxY - safeBottom)
            guard lastInset != inset else { return }
            lastInset = inset
            let insetChanged = insetChanged
            DispatchQueue.main.async { insetChanged?(inset) }
        }
    }
}
