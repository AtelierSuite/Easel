import Paintbrush
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
/// The editor: the canvas, the tools over it, and the panels beside it.
///
/// On iPhone the tools are a carousel along the bottom, with the settings
/// of the tool in hand just above it, and panels rise as sheets. On iPad the
/// tools are a rail down the side and panels live in an inspector.
///
/// Hosts — a document window, a photo opened from the library, the Photos
/// editing extension — supply the picture and add their own toolbar items.
/// A host's own action, such as sharing, goes in `actions`, grouped with the
/// "…" menu. A host whose file is never edited in place supplies
/// `copyBeforeEditing`, and the person is asked to save a copy at their
/// first edit.
struct EditorView<Actions: View>: View {
    @Binding var composition: Composition
    private let copyBeforeEditing: CopyBeforeEditing?
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
    @State private var isShowingUnsupportedFeatures = false

    init(
        composition: Binding<Composition>, copyBeforeEditing: CopyBeforeEditing? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        _composition = composition
        self.copyBeforeEditing = copyBeforeEditing
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
            .background(Color.workspace.ignoresSafeArea())
            .background { KeyboardCommands(state: state) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCompact {
                    VStack(spacing: 8) {
                        LinkedFilesBanner(state: state)
                        HStack(spacing: 0) {
                            ToolOptionsBar(state: state)
                            layersButton
                                .padding(.trailing, 12)
                        }
                        ToolPicker(layout: .carousel, state: state, namespace: panelTransition)
                    }
                    .canvasStatus(state)
                    .padding(.bottom, 8 + bottomToolbarInset)
                } else {
                    VStack(spacing: 8) {
                        LinkedFilesBanner(state: state)
                        ToolOptionsBar(state: state)
                    }
                    .canvasStatus(state)
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
            .onChange(of: isCompact, initial: true) { _, _ in updateInsets() }
            .onChange(of: state.presentedPanel) { _, panel in
                panelDetent = panel?.keepsCanvasVisible == false ? .large : .medium
                updateInsets()
                if !isCompact, panel != nil { state.isInspectorPresented = true }
            }
            .animation(.snappy(duration: 0.3), value: state.canvasInsets)
            .animation(.snappy(duration: 0.3), value: state.missingLinkNames + state.missingMapNames)
            .modifier(InspectorPresentation(isEnabled: !isCompact, isPresented: $state.isInspectorPresented) {
                let panel = state.presentedPanel ?? .layers
                EditorPanelContent(panel: panel, state: state, history: history)
                    .environment(\.panelPlacement, .inspector)
                    .environment(\.panelTitle, panel.title)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            })
            .sheet(item: Binding(
                get: { isCompact ? state.presentedPanel : nil },
                set: { state.presentedPanel = $0 }
            )) { panel in
                NavigationStack {
                    EditorPanelContent(panel: panel, state: state, history: history)
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
                .copyBeforeEditingAlert(state, isActive: true)
            }
            .toolbar { editingToolbar }
            .sheet(isPresented: $isShowingUnsupportedFeatures) {
                UnsupportedFeatureNotice(losses: composition.writeBackLosses)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.scrolls)
            }
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
            .copyBeforeEditingAlert(state, isActive: !isCompact || state.presentedPanel == nil)
            .selectionEditAlert(state)
            .fullScreenCover(item: $state.editingSmartObject) { editing in
                SmartObjectEditor(state: state, layerID: editing.layerID)
            }
            .onAppear(perform: attach)
            .onChange(of: composition) { _, new in state.sync(new) }
            #if DEBUG
            .modifier(ScreenshotFocus(state: state))
            #endif
    }

    private func attach() {
        let binding = $composition
        state.attach(to: composition) { binding.wrappedValue = $0 }
        state.copyBeforeEditing = copyBeforeEditing
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
                Button("Panel.History.Title", systemImage: EditorPanel.history.symbolName) {
                    state.presentedPanel = .history
                }
            }
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
            Section {
                if !composition.writeBackLosses.isEmpty {
                    Button("Toolbar.UnsupportedFeatures", systemImage: "exclamationmark.triangle") {
                        isShowingUnsupportedFeatures = true
                    }
                    .accessibilityIdentifier("unsupportedFeatures")
                }
                // An extension cannot open a link, so the Photos one leaves it out.
                if Bundle.main.bundleURL.pathExtension != "appex" {
                    Link(destination: URL(string: "https://github.com/AtelierSuite/Easel")!) {
                        Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
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
#endif
