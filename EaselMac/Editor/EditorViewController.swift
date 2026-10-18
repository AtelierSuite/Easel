import AppKit
import Paintbrush
import SwiftUI

/// An editor: the canvas, with the tools floating down its left, and the
/// inspector on the right. It answers the Edit, Image, Layer, View and Tools menus for the
/// picture it shows, wherever it is — a document's window or the sheet a
/// smart object's contents open in.
@MainActor
final class EditorViewController: NSSplitViewController {
    let session: EditorSession
    private let name: () -> String
    private var canvas: CanvasViewController!
    private(set) var inspectorItem: NSSplitViewItem!
    private var isFollowingInspector = false

    var state: EditorState { session.state }
    var history: CompositionHistory { session.history }

    init(session: EditorSession, name: @escaping () -> String) {
        self.session = session
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        canvas = CanvasViewController(
            rootView: CanvasArea(state: state, history: history, sheets: session.sheets, name: name),
            tools: ToolPaletteViewController(state: state)
        )
        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 360

        inspectorItem = NSSplitViewItem(inspectorWithViewController: InspectorViewController(session: session))
        inspectorItem.minimumThickness = 300
        inspectorItem.maximumThickness = 420
        inspectorItem.preferredThicknessFraction = 0.25
        inspectorItem.canCollapse = true

        splitViewItems = [canvasItem, inspectorItem]

        // A panel picked from a menu brings the inspector out.
        observeChanges { [weak self] in
            guard let self, state.presentedPanel != nil else { return }
            if inspectorItem.isCollapsed { inspectorItem.animator().isCollapsed = false }
        }
    }

    // MARK: - Undo

    /// Undo and Redo step through the picture's history. Text being typed
    /// in a panel is undone by its field first, which comes before this in
    /// the responder chain.
    @objc func undo(_ sender: Any?) { history.undo() }
    @objc func redo(_ sender: Any?) { history.redo() }

    private var undoTitle: String {
        guard history.canUndo, history.steps.indices.contains(history.position) else { return String(localized: "Toolbar.Undo") }
        return String(localized: "Menu.Undo \(history.steps[history.position])")
    }

    private var redoTitle: String {
        guard history.canRedo, history.steps.indices.contains(history.position + 1) else { return String(localized: "Toolbar.Redo") }
        return String(localized: "Menu.Redo \(history.steps[history.position + 1])")
    }

    // MARK: - Edit

    @objc func cut(_ sender: Any?) { state.cutToClipboard() }
    @objc func copy(_ sender: Any?) { state.copyToClipboard() }
    @objc func paste(_ sender: Any?) { state.pasteFromClipboard() }
    @objc override func selectAll(_ sender: Any?) { state.selectAll() }
    @objc func delete(_ sender: Any?) { state.clearSelection() }
    @objc func deselect(_ sender: Any?) { state.deselect() }
    @objc func invertSelection(_ sender: Any?) { state.invertSelection() }
    @objc func fillSelection(_ sender: Any?) { state.fillSelection() }
    @objc func cropToSelection(_ sender: Any?) { state.cropToSelection() }

    // MARK: - Image

    @objc func showImageSize(_ sender: Any?) { state.presentedPanel = .imageSize }
    @objc func rotateCanvasLeft(_ sender: Any?) { state.rotateCanvas(clockwise: false) }
    @objc func rotateCanvasRight(_ sender: Any?) { state.rotateCanvas(clockwise: true) }
    @objc func flipCanvasHorizontally(_ sender: Any?) { state.flipCanvas(horizontal: true) }
    @objc func flipCanvasVertically(_ sender: Any?) { state.flipCanvas(horizontal: false) }
    @objc func importImage(_ sender: Any?) { state.isImportingFiles = true }

    // MARK: - Layer

    @objc func newLayer(_ sender: Any?) { state.addEmptyLayer() }

    @objc func duplicateLayer(_ sender: Any?) {
        if let id = state.activeLayerID { state.duplicateLayer(id) }
    }

    @objc func mergeLayerDown(_ sender: Any?) {
        if let id = state.activeLayerID { state.mergeDown(id) }
    }

    @objc func deleteLayer(_ sender: Any?) {
        if let id = state.activeLayerID, state.canDelete(id) { state.deleteLayer(id) }
    }

    @objc func flattenImage(_ sender: Any?) { state.flatten() }

    @objc func moveLayerUp(_ sender: Any?) {
        if let id = state.activeLayerID { state.moveLayer(id, by: 1) }
    }

    @objc func moveLayerDown(_ sender: Any?) {
        if let id = state.activeLayerID { state.moveLayer(id, by: -1) }
    }

    @objc func toggleLayerVisibility(_ sender: Any?) {
        if let layer = state.activeLayer { state.setVisibility(!layer.isVisible, of: layer.id) }
    }

    @objc func toggleLayerLock(_ sender: Any?) {
        if let layer = state.activeLayer { state.setLocked(!layer.isLocked, of: layer.id) }
    }

    @objc func groupLayer(_ sender: Any?) { state.groupActiveLayer() }

    @objc func rasterizeLayer(_ sender: Any?) {
        if let id = state.activeLayerID { state.rasterizeLayer(id) }
    }

    @objc func convertToSmartObject(_ sender: Any?) { state.convertToSmartObject() }
    @objc func editSmartObjectContents(_ sender: Any?) { state.editSmartObjectContents() }
    @objc func addMask(_ sender: Any?) { state.addMask() }
    @objc func applyMask(_ sender: Any?) { state.applyMask() }
    @objc func invertMask(_ sender: Any?) { state.invertMask() }
    @objc func deleteMask(_ sender: Any?) { state.deleteMask() }

    // MARK: - View

    @objc func zoomIn(_ sender: Any?) { state.zoomStep(larger: true) }
    @objc func zoomOut(_ sender: Any?) { state.zoomStep(larger: false) }

    @objc func zoomToFit(_ sender: Any?) {
        withAnimation(.snappy) { state.fitCanvas() }
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        let scale = view.window?.backingScaleFactor ?? 2
        withAnimation(.snappy) { state.zoomToActualSize(displayScale: scale) }
    }

    @objc func toggleRulers(_ sender: Any?) { state.showsRulers.toggle() }

    @objc func toggleTools(_ sender: Any?) { canvas.showsTools.toggle() }

    @objc func toggleRotatesWithGestures(_ sender: Any?) {
        withAnimation(.snappy) { state.rotatesWithGestures.toggle() }
    }

    @objc func clearGuides(_ sender: Any?) { state.clearGuides() }

    /// Shows the panel a menu item's tag picks out of `EditorPanel`'s tabs.
    @objc func showPanel(_ sender: NSMenuItem) {
        guard InspectorViewController.tabbedPanels.indices.contains(sender.tag) else { return }
        state.presentedPanel = InspectorViewController.tabbedPanels[sender.tag]
    }

    @objc func showUnsupportedFeatures(_ sender: Any?) { session.sheets.isShowingUnsupportedFeatures = true }

    // MARK: - Tools

    /// Picks the tool a menu item's tag picks out of `Tool.allCases`.
    @objc func pickTool(_ sender: NSMenuItem) {
        guard Tool.allCases.indices.contains(sender.tag) else { return }
        state.tool = Tool.allCases[sender.tag]
    }

    @objc func smallerBrush(_ sender: Any?) { state.stepBrushSize(larger: false) }
    @objc func largerBrush(_ sender: Any?) { state.stepBrushSize(larger: true) }

    // MARK: - Keys

    /// Keys the canvas leaves alone reach here: the arrows nudge the layer,
    /// the brackets size the brush and a tool's letter picks it, as in other
    /// desktop editors.
    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        let step: Double = modifiers.contains(.shift) ? 10 : 1
        switch event.specialKey {
        case .leftArrow?: state.nudge(dx: -step, dy: 0); return true
        case .rightArrow?: state.nudge(dx: step, dy: 0); return true
        case .upArrow?: state.nudge(dx: 0, dy: -step); return true
        case .downArrow?: state.nudge(dx: 0, dy: step); return true
        case .delete?, .deleteForward?:
            state.clearSelection()
            return true
        default: break
        }
        guard !modifiers.contains(.shift), let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            return false
        }
        // Single keys, and so not in the menus, where they would take the
        // letters typed into fields.
        if key == "[" || key == "]" {
            state.stepBrushSize(larger: key == "]")
            return true
        }
        if let tool = Tool.allCases.first(where: { String($0.shortcut.character) == key }) {
            state.tool = tool
            return true
        }
        return false
    }
}

extension EditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasLayer = state.activeLayer != nil
        let hasSelection = state.selection != nil
        switch item.action {
        case #selector(undo(_:)):
            item.title = undoTitle
            return history.canUndo
        case #selector(redo(_:)):
            item.title = redoTitle
            return history.canRedo
        case #selector(cut(_:)), #selector(deselect(_:)), #selector(invertSelection(_:)), #selector(delete(_:)),
             #selector(fillSelection(_:)), #selector(cropToSelection(_:)):
            return hasSelection
        case #selector(copy(_:)):
            return hasLayer
        case #selector(duplicateLayer(_:)), #selector(groupLayer(_:)), #selector(moveLayerUp(_:)), #selector(moveLayerDown(_:)):
            return hasLayer
        case #selector(mergeLayerDown(_:)):
            guard let id = state.activeLayerID, let index = state.composition.index(of: id) else { return false }
            return index > 0
        case #selector(deleteLayer(_:)):
            return state.activeLayerID.map(state.canDelete) ?? false
        case #selector(toggleLayerVisibility(_:)):
            item.title = state.activeLayer?.isVisible == false
                ? String(localized: "Layers.Show") : String(localized: "Layers.Hide")
            return hasLayer
        case #selector(toggleLayerLock(_:)):
            item.title = state.activeLayer?.isLocked == true
                ? String(localized: "Layers.Unlock") : String(localized: "Layers.Lock")
            return hasLayer
        case #selector(rasterizeLayer(_:)):
            guard let layer = state.activeLayer else { return false }
            return layer.isText || layer.isVector || layer.isSmartObject
        case #selector(convertToSmartObject(_:)):
            guard let layer = state.activeLayer else { return false }
            return !layer.isSmartObject && !layer.isAdjustment
        case #selector(editSmartObjectContents(_:)):
            return state.activeLayer?.isSmartObject == true
        case #selector(addMask(_:)):
            return hasLayer && state.activeLayer?.mask == nil
        case #selector(applyMask(_:)), #selector(invertMask(_:)), #selector(deleteMask(_:)):
            return state.activeLayer?.mask != nil
        case #selector(flattenImage(_:)):
            return state.composition.layers.count > 1
        case #selector(toggleRulers(_:)):
            item.state = state.showsRulers ? .on : .off
        case #selector(toggleTools(_:)):
            item.state = canvas.showsTools ? .on : .off
        case #selector(toggleRotatesWithGestures(_:)):
            item.state = state.rotatesWithGestures ? .on : .off
        case #selector(clearGuides(_:)):
            return !state.composition.guides.isEmpty
        case #selector(showPanel(_:)):
            let panel = InspectorViewController.tabbedPanels.indices.contains(item.tag)
                ? InspectorViewController.tabbedPanels[item.tag] : nil
            item.state = panel != nil && panel == (state.presentedPanel ?? .layers) && !inspectorItem.isCollapsed ? .on : .off
        case #selector(pickTool(_:)):
            item.state = Tool.allCases.indices.contains(item.tag) && Tool.allCases[item.tag] == state.tool ? .on : .off
        case #selector(showUnsupportedFeatures(_:)):
            return !state.composition.writeBackLosses.isEmpty
        default:
            break
        }
        return true
    }
}

extension EditorViewController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): history.canUndo
        case #selector(redo(_:)): history.canRedo
        default: true
        }
    }
}

/// Holds the canvas inside the space the inspector and the toolbar leave
/// clear, with the tools floating over its left side. The canvas fits the
/// picture to the view it is given, so it is given only the part that can
/// be seen, and keeps the picture and its bars clear of the tools.
@MainActor
private final class CanvasViewController: NSViewController {
    private let hosting: NSHostingView<CanvasArea>
    private let tools: ToolPaletteViewController
    private var state: EditorState { hosting.rootView.state }

    static let margin: CGFloat = 12

    var showsTools = true {
        didSet {
            let palette = tools.view
            palette.isHidden = false
            NSAnimationContext.runAnimationGroup { _ in
                palette.animator().alphaValue = showsTools ? 1 : 0
            } completionHandler: { [showsTools] in
                // Hidden once faded, so it no longer takes clicks.
                MainActor.assumeIsolated { palette.isHidden = !showsTools }
            }
            updateInsets()
        }
    }

    init(rootView: CanvasArea, tools: ToolPaletteViewController) {
        hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
        addChild(tools)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = WorkspaceView()
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        let palette = tools.view
        palette.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(palette)
        let safe = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: safe.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            palette.leadingAnchor.constraint(equalTo: hosting.leadingAnchor, constant: Self.margin),
            palette.centerYAnchor.constraint(equalTo: hosting.centerYAnchor),
            palette.topAnchor.constraint(greaterThanOrEqualTo: hosting.topAnchor, constant: Self.margin),
            palette.bottomAnchor.constraint(lessThanOrEqualTo: hosting.bottomAnchor, constant: -Self.margin),
        ])
        view = container
        updateInsets()
    }

    /// The picture fits, and the bars along the bottom sit, beside the tools.
    private func updateInsets() {
        let leading = showsTools ? Self.margin + ToolPaletteViewController.width + 8 : 8
        withAnimation(.snappy(duration: 0.3)) {
            state.canvasInsets = EdgeInsets(top: 8, leading: leading, bottom: 8, trailing: 8)
        }
    }
}

/// The workspace colour, under the bars that float over the canvas.
private final class WorkspaceView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
}
