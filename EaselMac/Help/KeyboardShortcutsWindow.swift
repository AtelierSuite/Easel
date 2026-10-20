import AppKit
import Paintbrush
import SwiftUI

/// The Help menu's Keyboard Shortcuts window: every shortcut by what it is
/// for, each with a small picture that does what it does when its keys are
/// pressed or it is clicked, to learn them by trying them.
@MainActor
final class KeyboardShortcutsWindowController: NSWindowController {
    static let shared = KeyboardShortcutsWindowController()

    private let demo = ShortcutDemo()
    private var monitor: Any?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Shortcuts.Title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        let hosting = NSHostingView(rootView: KeyboardShortcutsView(demo: demo))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()
        window.setFrameAutosaveName("KeyboardShortcuts")
        super.init(window: window)
        // Ahead of the menus, so the keys tried here work the picture here
        // and not the document behind.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { @MainActor [weak self] event in
            guard let self, event.window === self.window, self.demo.handle(event) else { return event }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Shortcuts

/// A key with the modifiers held for it.
struct KeyCombo: Hashable {
    enum Key: Hashable {
        case character(String)
        case left, right, up, down
        case delete
        case space
    }

    var modifiers: NSEvent.ModifierFlags.RawValue
    var key: Key

    init(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func matches(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection(Self.relevant)
        switch key {
        case .left: return held.rawValue == modifiers && event.specialKey == .leftArrow
        case .right: return held.rawValue == modifiers && event.specialKey == .rightArrow
        case .up: return held.rawValue == modifiers && event.specialKey == .upArrow
        case .down: return held.rawValue == modifiers && event.specialKey == .downArrow
        case .delete:
            return held.rawValue == modifiers && (event.specialKey == .delete || event.specialKey == .deleteForward)
        case .space:
            return held.rawValue == modifiers && event.charactersIgnoringModifiers == " "
        case .character(let character):
            // The key's own character, whatever Shift makes of it.
            guard let typed = event.characters(byApplyingModifiers: [])?.lowercased() else { return false }
            if character == "+" {
                // Zooming in answers to the key + is on, with Shift or without.
                return held.subtracting(.shift).rawValue == modifiers && (typed == "=" || typed == "+")
            }
            return held.rawValue == modifiers && typed == character.lowercased()
        }
    }

    /// The modifiers' symbols, in the order menus show them.
    var modifierSymbols: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
    }

    var keyLabel: String {
        switch key {
        case .character(let character): character.uppercased()
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .delete: "⌫"
        case .space: String(localized: "Shortcuts.Space")
        }
    }
}

/// One thing a shortcut does: its name, the keys for it, and what it does
/// to the demo. A row with several keys either takes any of them, as the
/// arrows do, or runs through them, as the tab numbers do.
struct ShortcutRow: Identifiable {
    let id: String
    let title: String
    let combos: [KeyCombo]
    /// Whether the keys run from the first to the last, shown as such.
    var isRange = false
    /// What follows the keys, such as a drag.
    var suffix: String?
    let perform: @MainActor (ShortcutDemo, Int) -> Void
}

enum ShortcutCategory: String, CaseIterable, Identifiable {
    case tools, brush, layers, selection, editing, view, documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: String(localized: "Shortcuts.Category.Tools")
        case .brush: String(localized: "Shortcuts.Category.Brush")
        case .layers: String(localized: "Shortcuts.Category.Layers")
        case .selection: String(localized: "Shortcuts.Category.Selection")
        case .editing: String(localized: "Shortcuts.Category.Editing")
        case .view: String(localized: "Shortcuts.Category.View")
        case .documents: String(localized: "Shortcuts.Category.Documents")
        }
    }

    var intro: String {
        switch self {
        case .tools: String(localized: "Shortcuts.Intro.Tools")
        case .brush: String(localized: "Shortcuts.Intro.Brush")
        case .layers: String(localized: "Shortcuts.Intro.Layers")
        case .selection: String(localized: "Shortcuts.Intro.Selection")
        case .editing: String(localized: "Shortcuts.Intro.Editing")
        case .view: String(localized: "Shortcuts.Intro.View")
        case .documents: String(localized: "Shortcuts.Intro.Documents")
        }
    }

    var symbolName: String {
        switch self {
        case .tools: "wrench.and.screwdriver"
        case .brush: "paintbrush.pointed"
        case .layers: "square.3.layers.3d"
        case .selection: "rectangle.dashed"
        case .editing: "arrow.uturn.backward"
        case .view: "macwindow"
        case .documents: "doc"
        }
    }

    /// The shortcuts, with their keys read from the menu bar where they are
    /// in it, so this always shows what the menus do.
    @MainActor var rows: [ShortcutRow] {
        switch self {
        case .tools:
            return Tool.allCases.map { tool in
                ShortcutRow(
                    id: "tool.\(tool.rawValue)",
                    title: String(localized: String.LocalizationValue(tool.labelKey)),
                    combos: [KeyCombo(.character(String(tool.shortcut.character)))]
                ) { demo, _ in demo.tool = tool }
            }
        case .brush:
            return [
                ShortcutRow(id: "brush.smaller", title: String(localized: "Menu.SmallerBrush"), combos: [KeyCombo(.character("["))]) { demo, _ in
                    demo.stepBrushSize(larger: false)
                },
                ShortcutRow(id: "brush.larger", title: String(localized: "Menu.LargerBrush"), combos: [KeyCombo(.character("]"))]) { demo, _ in
                    demo.stepBrushSize(larger: true)
                },
                ShortcutRow(id: "brush.softer", title: String(localized: "Menu.SofterBrush"), combos: [KeyCombo(.character("["), .shift)]) { demo, _ in
                    demo.stepSoftness(softer: true)
                },
                ShortcutRow(id: "brush.harder", title: String(localized: "Menu.HarderBrush"), combos: [KeyCombo(.character("]"), .shift)]) { demo, _ in
                    demo.stepSoftness(softer: false)
                },
                ShortcutRow(
                    id: "brush.opacity",
                    title: String(localized: "Shortcuts.Opacity"),
                    combos: (1...10).map { KeyCombo(.character(String($0 % 10))) },
                    isRange: true
                ) { demo, index in
                    demo.opacity = Double(index + 1) / 10
                },
            ]
        case .layers:
            return [
                Self.menuRow("layers.new", "Layers.NewLayer", #selector(EditorViewController.newLayer(_:))) { $0.addLayer() },
                Self.menuRow("layers.duplicate", "Layers.Duplicate", #selector(EditorViewController.duplicateLayer(_:))) { $0.duplicateLayer() },
                Self.menuRow("layers.merge", "Layers.MergeDown", #selector(EditorViewController.mergeLayerDown(_:))) { $0.mergeDown() },
                Self.menuRow("layers.group", "Groups.Group", #selector(EditorViewController.groupLayer(_:))) { $0.groupLayer() },
                Self.menuRow("layers.up", "Layers.MoveUp", #selector(EditorViewController.moveLayerUp(_:))) { $0.moveLayer(by: 1) },
                Self.menuRow("layers.down", "Layers.MoveDown", #selector(EditorViewController.moveLayerDown(_:))) { $0.moveLayer(by: -1) },
                Self.menuRow("layers.above", "Layers.SelectAbove", #selector(EditorViewController.selectLayerAbove(_:))) { $0.selectLayer(by: 1) },
                Self.menuRow("layers.below", "Layers.SelectBelow", #selector(EditorViewController.selectLayerBelow(_:))) { $0.selectLayer(by: -1) },
                Self.menuRow("layers.hide", "Shortcuts.HideLayer", #selector(EditorViewController.toggleLayerVisibility(_:))) { $0.toggleVisibility() },
                Self.menuRow("layers.lock", "Shortcuts.LockLayer", #selector(EditorViewController.toggleLayerLock(_:))) { $0.toggleLock() },
            ].compactMap { $0 }
        case .selection:
            let arrows: [KeyCombo.Key] = [.left, .right, .up, .down]
            return [
                Self.menuRow("select.all", "Select.All", #selector(EditorViewController.selectAll(_:))) { $0.selection = .all },
                Self.menuRow("select.deselect", "Select.Deselect", #selector(EditorViewController.deselect(_:))) { $0.selection = .none },
                Self.menuRow("select.invert", "Select.Invert", #selector(EditorViewController.invertSelection(_:))) { $0.invertSelection() },
                ShortcutRow(id: "select.clear", title: String(localized: "Select.Clear"), combos: [KeyCombo(.delete)]) { demo, _ in
                    demo.paintSelection(.clear)
                },
                ShortcutRow(id: "select.fill", title: String(localized: "Select.Fill"), combos: [KeyCombo(.delete, .option)]) { demo, _ in
                    demo.paintSelection(.fill)
                },
                ShortcutRow(id: "select.nudge", title: String(localized: "Shortcuts.Nudge"), combos: arrows.map { KeyCombo($0) }) { demo, index in
                    demo.nudge(arrows[index], by: 1)
                },
                ShortcutRow(id: "select.nudgeFar", title: String(localized: "Shortcuts.NudgeFar"), combos: arrows.map { KeyCombo($0, .shift) }) { demo, index in
                    demo.nudge(arrows[index], by: 10)
                },
            ].compactMap { $0 }
        case .editing:
            return [
                Self.menuRow("edit.undo", "Toolbar.Undo", #selector(EditorViewController.undo(_:))) { $0.undo() },
                Self.menuRow("edit.redo", "Toolbar.Redo", #selector(EditorViewController.redo(_:))) { $0.redo() },
                Self.menuRow("edit.cut", "Edit.Cut", #selector(EditorViewController.cut(_:))) { $0.cut() },
                Self.menuRow("edit.copy", "Edit.Copy", #selector(EditorViewController.copy(_:))) { $0.copy() },
                Self.menuRow("edit.paste", "Edit.Paste", #selector(EditorViewController.paste(_:))) { $0.paste() },
            ].compactMap { $0 }
        case .view:
            let panels = InspectorViewController.tabbedPanels.indices.compactMap { index in
                MainMenu.item(for: #selector(EditorViewController.showPanel(_:)), tag: index).map(KeyCombo.init(menuItem:))
            }
            return [
                Self.menuRow("view.zoomIn", "Menu.ZoomIn", #selector(EditorViewController.zoomIn(_:))) { $0.zoom(by: 1.25) },
                Self.menuRow("view.zoomOut", "Menu.ZoomOut", #selector(EditorViewController.zoomOut(_:))) { $0.zoom(by: 0.8) },
                Self.menuRow("view.fit", "Canvas.FitToScreen", #selector(EditorViewController.zoomToFit(_:))) { $0.fit() },
                Self.menuRow("view.actual", "Canvas.ActualSize", #selector(EditorViewController.zoomToActualSize(_:))) { $0.actualSize() },
                ShortcutRow(
                    id: "view.pan", title: String(localized: "Shortcuts.Pan"), combos: [KeyCombo(.space)],
                    suffix: String(localized: "Shortcuts.Drag")
                ) { demo, _ in
                    demo.isHoldingSpace = true
                },
                Self.menuRow("view.rulers", "Canvas.ShowRulers", #selector(EditorViewController.toggleRulers(_:))) { $0.showsRulers.toggle() },
                Self.menuRow("view.tools", "Menu.ShowTools", #selector(EditorViewController.toggleTools(_:))) { $0.showsTools.toggle() },
                Self.menuRow("view.inspector", "Toolbar.Inspector", #selector(NSSplitViewController.toggleInspector(_:))) {
                    $0.showsInspector.toggle()
                },
                panels.isEmpty ? nil : ShortcutRow(id: "view.panels", title: String(localized: "Shortcuts.Panels"), combos: panels, isRange: true) { demo, index in
                    demo.panel = index
                    demo.showsInspector = true
                },
                Self.menuRow("view.fonts", "Text.ShowFonts", #selector(EditorViewController.showFonts(_:))) { $0.showsFonts.toggle() },
                Self.menuRow("view.colors", "Swatches.ShowColors", #selector(EditorViewController.showColors(_:))) { $0.showsColors.toggle() },
                Self.menuRow("view.fullScreen", "Menu.EnterFullScreen", #selector(NSWindow.toggleFullScreen(_:))) { $0.isFullScreen.toggle() },
            ].compactMap { $0 }
        case .documents:
            return [
                Self.menuRow("doc.new", "Launch.NewImage", #selector(NSDocumentController.newDocument(_:))),
                Self.menuRow("doc.open", "Menu.Open", #selector(NSDocumentController.openDocument(_:))),
                Self.menuRow("doc.save", "Menu.Save", #selector(NSDocument.save(_:))),
                Self.menuRow("doc.duplicate", "Menu.Duplicate", #selector(NSDocument.duplicate(_:))),
                Self.menuRow("doc.close", "Menu.Close", #selector(NSWindow.performClose(_:))),
                Self.menuRow("doc.import", "Menu.ImportImage", #selector(EditorViewController.importImage(_:))),
                Self.menuRow("doc.export", "ExportPreset.Menu", #selector(EditorWindowController.exportWithPresets(_:))),
                Self.menuRow("doc.imageSize", "Canvas.ImageSize", #selector(EditorViewController.showImageSize(_:))),
            ].compactMap { $0 }
        }
    }

    /// A row whose keys are the menu item's, or nothing if the item has none.
    @MainActor private static func menuRow(
        _ id: String, _ titleKey: String, _ action: Selector, perform: @escaping @MainActor (ShortcutDemo) -> Void = { _ in }
    ) -> ShortcutRow? {
        guard let item = MainMenu.item(for: action), !item.keyEquivalent.isEmpty else { return nil }
        return ShortcutRow(id: id, title: String(localized: String.LocalizationValue(titleKey)), combos: [KeyCombo(menuItem: item)]) { demo, _ in
            perform(demo)
        }
    }
}

extension KeyCombo {
    init(menuItem: NSMenuItem) {
        self.init(.character(menuItem.keyEquivalent), menuItem.keyEquivalentModifierMask)
    }
}

extension MainMenu {
    /// The menu bar's item for an action, and a tag where items share one.
    static func item(for action: Selector, tag: Int? = nil, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action, tag == nil || item.tag == tag { return item }
            if let found = item.submenu.flatMap({ Self.item(for: action, tag: tag, in: $0) }) { return found }
        }
        return nil
    }
}

// MARK: - Demo

/// The pictures the shortcuts work on, one for each kind, and which
/// shortcuts have been tried.
@MainActor
@Observable
final class ShortcutDemo {
    var category: ShortcutCategory? = .tools {
        didSet { isHoldingSpace = false }
    }
    /// The shortcut last used, lit in the list and spelt out over the demo.
    private(set) var pressed: (row: ShortcutRow, combo: KeyCombo)?
    private(set) var pressCount = 0
    private(set) var tried: Set<String> = []
    private var releaseTask: Task<Void, Never>?

    // Tools
    var tool: Tool = .brush

    // Brush
    var brushSize = 24.0
    var softness = 0.0
    var opacity = 1.0

    // Layers
    struct DemoLayer: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var hue: Double
        var isVisible = true
        var isLocked = false
        /// The layers a group holds, by name.
        var members: [String] = []
    }
    /// Bottom first, as a picture keeps them.
    var layers: [DemoLayer] = ShortcutDemo.startingLayers
    var activeLayer = 2
    private var layerCount = 3

    // Selection
    enum DemoSelection: Equatable { case none, rect, all, inverted }
    enum Paint { case fill, clear }
    struct PaintMark: Equatable {
        var kind: Paint
        var selection: DemoSelection
        /// Where the layer was, for the mark to move with it after.
        var layerOffset: CGSize
    }
    var selection: DemoSelection = .rect
    var layerOffset = CGSize.zero
    var paintMarks: [PaintMark] = []

    // Editing
    struct Mark: Equatable, Identifiable {
        let id = UUID()
        var position: CGPoint
        var hue: Double
    }
    var history: [[Mark]] = ShortcutDemo.startingHistory
    var historyIndex = ShortcutDemo.startingHistory.count - 1
    var clipboard: Mark?
    var marks: [Mark] { history[historyIndex] }

    // View
    var zoom = 1.0
    var pan = CGSize.zero
    var isHoldingSpace = false
    var showsRulers = false
    var showsTools = true
    var showsInspector = true
    var panel = 0
    var showsFonts = false
    var showsColors = false
    var isFullScreen = false

    /// Runs the shortcut a key press is for in the category shown, if any.
    func handle(_ event: NSEvent) -> Bool {
        guard let category else { return false }
        if event.type == .keyUp {
            guard isHoldingSpace, event.charactersIgnoringModifiers == " " else { return false }
            isHoldingSpace = false
            return true
        }
        // Closing the window stays closing it, on the page that lists it too.
        if event.modifierFlags.intersection(KeyCombo.relevant) == .command, event.charactersIgnoringModifiers == "w" {
            return false
        }
        for row in category.rows {
            if let index = row.combos.firstIndex(where: { $0.matches(event) }) {
                if !event.isARepeat || row.id.hasPrefix("select.nudge") || row.id.hasPrefix("brush.") || row.id.hasPrefix("view.zoom") {
                    run(row, combo: index)
                }
                return true
            }
        }
        return false
    }

    /// Does what a shortcut does, as if its keys had been pressed.
    func run(_ row: ShortcutRow, combo index: Int = 0) {
        withAnimation(.snappy) { row.perform(self, index) }
        pressed = (row, row.combos[index])
        pressCount += 1
        tried.insert(row.id)
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { pressed = nil }
        }
    }

    func isTried(_ row: ShortcutRow) -> Bool { tried.contains(row.id) }

    /// Puts the category's picture back as it started.
    func reset(_ category: ShortcutCategory) {
        withAnimation(.snappy) {
            switch category {
            case .tools: tool = .brush
            case .brush: (brushSize, softness, opacity) = (24, 0, 1)
            case .layers: (layers, activeLayer, layerCount) = (Self.startingLayers, 2, 3)
            case .selection: (selection, layerOffset, paintMarks) = (.rect, .zero, [])
            case .editing: (history, historyIndex, clipboard) = (Self.startingHistory, Self.startingHistory.count - 1, nil)
            case .view:
                (zoom, pan, showsRulers, showsTools, showsInspector) = (1, .zero, false, true, true)
                (panel, showsFonts, showsColors, isFullScreen) = (0, false, false, false)
            case .documents: break
            }
        }
    }

    // MARK: Brush

    func stepBrushSize(larger: Bool) {
        let position = BrushSizeScale.position(for: brushSize) + (larger ? 0.03 : -0.03)
        brushSize = max(BrushSettings.sizeRange.lowerBound, BrushSizeScale.size(at: min(max(position, 0), 1)))
    }

    func stepSoftness(softer: Bool) {
        softness = min(max((softness * 4).rounded() + (softer ? 1 : -1), 0), 4) / 4
    }

    // MARK: Layers

    static var startingLayers: [DemoLayer] {
        let name = String(localized: "Layer.DefaultName.Layer")
        return [
            DemoLayer(name: String(localized: "Layer.DefaultName.Background"), hue: 0.58),
            DemoLayer(name: "\(name) 1", hue: 0.33),
            DemoLayer(name: "\(name) 2", hue: 0.08),
        ]
    }

    func addLayer() {
        layerCount += 1
        let layer = DemoLayer(name: "\(String(localized: "Layer.DefaultName.Layer")) \(layerCount)", hue: Double(layerCount) * 0.17)
        layers.insert(layer, at: activeLayer + 1)
        activeLayer += 1
    }

    func duplicateLayer() {
        guard layers.indices.contains(activeLayer) else { return }
        var copy = layers[activeLayer]
        copy = DemoLayer(name: String(localized: "Layer.CopyName \(copy.name)"), hue: copy.hue, isVisible: copy.isVisible, members: copy.members)
        layers.insert(copy, at: activeLayer + 1)
        activeLayer += 1
    }

    func mergeDown() {
        guard activeLayer > 0, layers.indices.contains(activeLayer) else { return }
        layers.remove(at: activeLayer)
        activeLayer -= 1
    }

    func groupLayer() {
        guard layers.indices.contains(activeLayer), layers[activeLayer].members.isEmpty else { return }
        let layer = layers[activeLayer]
        layers[activeLayer] = DemoLayer(
            name: String(localized: "Layer.DefaultName.Group"), hue: layer.hue, members: [layer.name]
        )
    }

    func moveLayer(by offset: Int) {
        let target = activeLayer + offset
        guard layers.indices.contains(activeLayer), layers.indices.contains(target) else { return }
        layers.swapAt(activeLayer, target)
        activeLayer = target
    }

    func selectLayer(by offset: Int) {
        let target = activeLayer + offset
        if layers.indices.contains(target) { activeLayer = target }
    }

    func toggleVisibility() {
        if layers.indices.contains(activeLayer) { layers[activeLayer].isVisible.toggle() }
    }

    func toggleLock() {
        if layers.indices.contains(activeLayer) { layers[activeLayer].isLocked.toggle() }
    }

    // MARK: Selection

    func invertSelection() {
        switch selection {
        case .rect: selection = .inverted
        case .inverted: selection = .rect
        case .all: selection = .none
        case .none: break
        }
    }

    func paintSelection(_ kind: Paint) {
        guard selection != .none else { return }
        paintMarks.append(PaintMark(kind: kind, selection: selection, layerOffset: layerOffset))
    }

    func nudge(_ direction: KeyCombo.Key, by step: Double) {
        switch direction {
        case .left: layerOffset.width -= step
        case .right: layerOffset.width += step
        case .up: layerOffset.height -= step
        case .down: layerOffset.height += step
        default: break
        }
    }

    // MARK: Editing

    static var startingHistory: [[Mark]] {
        let marks = [
            Mark(position: CGPoint(x: 0.25, y: 0.45), hue: 0.0),
            Mark(position: CGPoint(x: 0.45, y: 0.6), hue: 0.12),
            Mark(position: CGPoint(x: 0.62, y: 0.4), hue: 0.55),
        ]
        return (0...marks.count).map { Array(marks.prefix($0)) }
    }

    func undo() { historyIndex = max(historyIndex - 1, 0) }
    func redo() { historyIndex = min(historyIndex + 1, history.count - 1) }

    private func record(_ marks: [Mark]) {
        history = Array(history.prefix(historyIndex + 1)) + [marks]
        historyIndex = history.count - 1
    }

    func copy() { clipboard = marks.last }

    func cut() {
        guard let last = marks.last else { return }
        clipboard = last
        record(Array(marks.dropLast()))
    }

    func paste() {
        guard var mark = clipboard else { return }
        let offset = 0.06 * Double(marks.count % 4 + 1)
        mark = Mark(
            position: CGPoint(x: min(mark.position.x + offset, 0.85), y: max(mark.position.y - offset, 0.2)), hue: mark.hue
        )
        record(marks + [mark])
    }

    // MARK: View

    /// How large the picture shows at full size, as a share of fitting it.
    static let actualZoom = 3.0

    func zoom(by factor: Double) { zoom = min(max(zoom * factor, 0.25), 12) }

    func fit() {
        zoom = 1
        pan = .zero
    }

    func actualSize() { zoom = Self.actualZoom }

    var zoomPercent: Int { Int((zoom / Self.actualZoom * 100).rounded()) }
}

// MARK: - Window content

struct KeyboardShortcutsView: View {
    @Bindable var demo: ShortcutDemo

    var body: some View {
        HStack(spacing: 0) {
            List(ShortcutCategory.allCases, selection: $demo.category) { category in
                let rows = category.rows
                let tried = rows.filter(demo.isTried).count
                Label {
                    HStack {
                        Text(verbatim: category.title)
                        Spacer()
                        if tried == rows.count, !rows.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if tried > 0 {
                            Text(verbatim: "\(tried)/\(rows.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: category.symbolName)
                }
                .tag(category)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            Group {
                if let category = demo.category {
                    CategoryPage(demo: demo, category: category)
                        .id(category)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CategoryPage: View {
    let demo: ShortcutDemo
    let category: ShortcutCategory

    var body: some View {
        let rows = category.rows
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: category.title)
                    .font(.title2.bold())
                Text(verbatim: category.intro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            DemoStage(demo: demo, category: category)
                .frame(height: 250)
                .padding(.horizontal, 20)

            HStack {
                Label("Shortcuts.TryIt", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Shortcuts.Tried \(rows.filter(demo.isTried).count) \(rows.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if category != .documents {
                    Button("Shortcuts.Reset") { demo.reset(category) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                List(rows) { row in
                    ShortcutRowView(demo: demo, row: row)
                        .id(row.id)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .onChange(of: demo.pressCount) {
                    guard let id = demo.pressed?.row.id else { return }
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct ShortcutRowView: View {
    let demo: ShortcutDemo
    let row: ShortcutRow

    var body: some View {
        let isPressed = demo.pressed?.row.id == row.id
        Button {
            demo.run(row)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: demo.isTried(row) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(demo.isTried(row) ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: row.title)
                Spacer()
                KeysView(row: row, pressed: isPressed ? demo.pressed?.combo : nil)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(isPressed ? Color.accentColor.opacity(0.15) : nil)
    }
}

/// A row's keys as keycaps: each way to press it, or the first and last of
/// a run.
private struct KeysView: View {
    let row: ShortcutRow
    let pressed: KeyCombo?

    var body: some View {
        HStack(spacing: 6) {
            if row.isRange, let first = row.combos.first, let last = row.combos.last {
                ComboCaps(combo: first, isPressed: pressed == first)
                Text(verbatim: "…").foregroundStyle(.secondary)
                ComboCaps(combo: last, isPressed: pressed == last)
            } else if row.combos.count > 1, let first = row.combos.first, row.combos.allSatisfy({ $0.modifiers == first.modifiers }) {
                // The modifiers held for any of the keys, once.
                ForEach(Array(first.modifierSymbols.map(String.init).enumerated()), id: \.offset) { _, symbol in
                    KeyCap(label: symbol, isPressed: pressed != nil)
                }
                ForEach(row.combos, id: \.self) { combo in
                    KeyCap(label: combo.keyLabel, isPressed: pressed == combo)
                }
            } else {
                ForEach(row.combos, id: \.self) { combo in
                    ComboCaps(combo: combo, isPressed: pressed == combo)
                }
            }
            if let suffix = row.suffix {
                Text(verbatim: "+ \(suffix)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One way to press a shortcut: a cap for each modifier, then the key's.
private struct ComboCaps: View {
    let combo: KeyCombo
    var isPressed = false
    var large = false

    var body: some View {
        HStack(spacing: large ? 6 : 3) {
            ForEach(Array(combo.modifierSymbols.map(String.init).enumerated()), id: \.offset) { _, symbol in
                KeyCap(label: symbol, isPressed: isPressed, large: large)
            }
            KeyCap(label: combo.keyLabel, isPressed: isPressed, large: large)
        }
    }
}

private struct KeyCap: View {
    let label: String
    var isPressed = false
    var large = false

    var body: some View {
        Text(verbatim: label)
            .font(large ? .title2.weight(.medium) : .callout.weight(.medium))
            .monospacedDigit()
            .frame(minWidth: large ? 40 : 22, minHeight: large ? 40 : 22)
            .padding(.horizontal, label.count > 1 ? (large ? 10 : 6) : 0)
            .background {
                RoundedRectangle(cornerRadius: large ? 8 : 5)
                    .fill(isPressed ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(isPressed ? 0 : 0.25), radius: 0, y: isPressed ? 0 : (large ? 2 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: large ? 8 : 5)
                    .strokeBorder(Color.secondary.opacity(0.35))
            }
            .offset(y: isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}

// MARK: - Demos

/// The category's picture, with the last shortcut used spelt out over it.
private struct DemoStage: View {
    let demo: ShortcutDemo
    let category: ShortcutCategory

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .underPageBackgroundColor))
            Group {
                switch category {
                case .tools: ToolsDemo(demo: demo)
                case .brush: BrushDemo(demo: demo)
                case .layers: LayersDemo(demo: demo)
                case .selection: SelectionDemo(demo: demo)
                case .editing: EditingDemo(demo: demo)
                case .view: ViewDemo(demo: demo)
                case .documents: DocumentsDemo()
                }
            }
            .padding(16)
            .padding(.bottom, 36)
            if let pressed = demo.pressed {
                HStack(spacing: 10) {
                    ComboCaps(combo: pressed.combo, isPressed: false)
                    Text(verbatim: pressed.row.title)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(demo.pressCount)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
    }
}

private struct ToolsDemo: View {
    let demo: ShortcutDemo

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(Tool.groups.enumerated()), id: \.offset) { _, tools in
                    // Two rows to a group, as many tools across as that takes.
                    let columns = (tools.count + 1) / 2
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: columns), spacing: 6) {
                        ForEach(tools) { tool in
                            toolTile(tool)
                        }
                    }
                    .frame(width: CGFloat(columns) * 44 - 6)
                }
            }
            Label {
                Text(LocalizedStringKey(demo.tool.labelKey))
            } icon: {
                Image(systemName: demo.tool.symbolName)
            }
            .font(.title3.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolTile(_ tool: Tool) -> some View {
        let isActive = demo.tool == tool
        return Button {
            if let row = ShortcutCategory.tools.rows.first(where: { $0.id == "tool.\(tool.rawValue)" }) { demo.run(row) }
        } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 15))
                .frame(width: 38, height: 38)
                .background(isActive ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                .foregroundStyle(isActive ? .white : .primary)
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: String(tool.shortcut.character).uppercased())
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .foregroundStyle(isActive ? .white : .secondary)
                        .padding(3)
                }
                .scaleEffect(isActive ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(tool.labelKey)))
    }
}

private struct BrushDemo: View {
    let demo: ShortcutDemo

    var body: some View {
        HStack(spacing: 24) {
            Canvas { context, size in
                // A wave of dabs, sized to the brush against a 400 pixel page.
                let scale = size.width / 400
                let diameter = max(demo.brushSize * scale, 1.5)
                let feather = demo.softness
                let color = Color.accentColor
                var layer = context
                layer.opacity = demo.opacity
                layer.drawLayer { dabs in
                    let step = max(diameter * 0.15, 1)
                    var x = diameter / 2 + 8
                    while x < size.width - diameter / 2 - 8 {
                        let y = size.height / 2 + sin(x / size.width * .pi * 2) * size.height * 0.22
                        let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
                        if feather > 0 {
                            dabs.fill(
                                Path(ellipseIn: rect),
                                with: .radialGradient(
                                    Gradient(stops: [
                                        .init(color: color, location: 0),
                                        .init(color: color, location: max(0, 1 - feather)),
                                        .init(color: color.opacity(0), location: 1),
                                    ]),
                                    center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: diameter / 2
                                )
                            )
                        } else {
                            dabs.fill(Path(ellipseIn: rect), with: .color(color))
                        }
                        x += step
                    }
                }
            }
            .background(Color.white, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 12) {
                readout("Options.Size", value: "\(Int(demo.brushSize.rounded())) px", fraction: BrushSizeScale.position(for: demo.brushSize))
                readout("Options.Softness", value: "\(Int((demo.softness * 100).rounded()))%", fraction: demo.softness)
                readout("Options.Opacity", value: "\(Int((demo.opacity * 100).rounded()))%", fraction: demo.opacity)
            }
            .frame(width: 180)
        }
    }

    private func readout(_ title: LocalizedStringKey, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .font(.callout)
            ProgressView(value: min(max(fraction, 0), 1))
        }
    }
}

private struct LayersDemo: View {
    let demo: ShortcutDemo

    var body: some View {
        HStack(spacing: 24) {
            // The picture the stack makes, bottom layer first.
            ZStack {
                ForEach(Array(demo.layers.enumerated()), id: \.element.id) { index, layer in
                    if layer.isVisible {
                        let inset = CGFloat(index) * 14
                        RoundedRectangle(cornerRadius: index == 0 ? 0 : 10)
                            .fill(Color(hue: layer.hue, saturation: index == 0 ? 0.25 : 0.6, brightness: 0.95))
                            .padding(index == 0 ? 0 : 18 + inset)
                            .offset(x: index == 0 ? 0 : CGFloat(index % 2 == 0 ? 12 : -12))
                    }
                }
            }
            .frame(width: 180, height: 180)
            .background(.white)
            .clipShape(.rect(cornerRadius: 8))

            VStack(spacing: 2) {
                ForEach(Array(demo.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                    layerRow(layer, isActive: index == demo.activeLayer)
                }
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func layerRow(_ layer: ShortcutDemo.DemoLayer, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .secondary)
                    .frame(width: 18)
                if layer.members.isEmpty {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hue: layer.hue, saturation: 0.6, brightness: 0.95))
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "folder")
                        .frame(width: 20)
                }
                Text(verbatim: layer.name)
                    .lineLimit(1)
                Spacer()
                if layer.isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(layer.members, id: \.self) { member in
                Text(verbatim: member)
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : .secondary)
                    .padding(.leading, 54)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isActive ? .white : .primary)
        .background(isActive ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .opacity(layer.isVisible ? 1 : 0.7)
        .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
    }
}

private struct SelectionDemo: View {
    let demo: ShortcutDemo

    var body: some View {
        GeometryReader { proxy in
            let page = CGRect(origin: .zero, size: proxy.size).insetBy(dx: max((proxy.size.width - 360) / 2, 0), dy: 0)
            let marquee = CGRect(x: page.minX + page.width * 0.3, y: page.height * 0.25, width: page.width * 0.4, height: page.height * 0.5)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.fill(Path(page), with: .color(.white))
                    context.clip(to: Path(page))
                    // The layer, with what has been filled or cleared in it.
                    context.drawLayer { layer in
                        layer.translateBy(x: demo.layerOffset.width * 2, y: demo.layerOffset.height * 2)
                        let blob = CGRect(x: page.midX - 70, y: page.midY - 55, width: 140, height: 110)
                        layer.fill(Path(ellipseIn: blob), with: .linearGradient(
                            Gradient(colors: [.orange, .pink]), startPoint: blob.origin, endPoint: CGPoint(x: blob.maxX, y: blob.maxY)
                        ))
                        for mark in demo.paintMarks {
                            var area = layer
                            // Back to where the selection was over the layer then.
                            area.translateBy(x: -mark.layerOffset.width * 2, y: -mark.layerOffset.height * 2)
                            let region: Path = switch mark.selection {
                            case .rect: Path(marquee)
                            case .all: Path(page)
                            case .inverted: Path(page).subtracting(Path(marquee))
                            case .none: Path()
                            }
                            if mark.kind == .clear { area.blendMode = .destinationOut }
                            area.fill(region, with: .color(mark.kind == .clear ? .black : .blue.opacity(0.8)))
                        }
                    }
                }
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 12
                    Canvas { context, _ in
                        let style = StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase)
                        switch demo.selection {
                        case .none: break
                        case .rect:
                            ants(context, Path(marquee), style)
                        case .all:
                            ants(context, Path(page.insetBy(dx: 1, dy: 1)), style)
                        case .inverted:
                            ants(context, Path(marquee), style)
                            ants(context, Path(page.insetBy(dx: 1, dy: 1)), style)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func ants(_ context: GraphicsContext, _ path: Path, _ style: StrokeStyle) {
        context.stroke(path, with: .color(.white), lineWidth: 1)
        context.stroke(path, with: .color(.black), style: style)
    }
}

private struct EditingDemo: View {
    let demo: ShortcutDemo

    var body: some View {
        HStack(spacing: 20) {
            GeometryReader { proxy in
                ZStack {
                    Color.white
                    ForEach(demo.marks) { mark in
                        Circle()
                            .fill(Color(hue: mark.hue, saturation: 0.7, brightness: 0.95))
                            .frame(width: 56, height: 56)
                            .position(x: mark.position.x * proxy.size.width, y: mark.position.y * proxy.size.height)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 14) {
                Text("Panel.History.Title")
                    .font(.callout.bold())
                HStack(spacing: 6) {
                    ForEach(demo.history.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == demo.historyIndex ? Color.accentColor : Color.secondary.opacity(index < demo.historyIndex ? 0.5 : 0.2))
                            .frame(width: 18, height: 26)
                    }
                }
                Divider()
                Text("Shortcuts.Clipboard")
                    .font(.callout.bold())
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if let mark = demo.clipboard {
                        Circle()
                            .fill(Color(hue: mark.hue, saturation: 0.7, brightness: 0.95))
                            .frame(width: 32, height: 32)
                            .transition(.scale)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 64, height: 52)
            }
            .frame(width: 200, alignment: .leading)
        }
    }
}

/// A small editor window, its picture zooming and panning and its panels
/// coming and going.
private struct ViewDemo: View {
    @Bindable var demo: ShortcutDemo
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let full = demo.isFullScreen
            let frame = full ? proxy.size : CGSize(width: min(proxy.size.width, 460), height: proxy.size.height)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if !full {
                        HStack(spacing: 5) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { color in
                                Circle().fill(color.opacity(0.8)).frame(width: 8, height: 8)
                            }
                            Spacer()
                            Text(verbatim: "\(demo.zoomPercent)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    HStack(spacing: 0) {
                        if demo.showsTools {
                            VStack(spacing: 6) {
                                ForEach(0..<6, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(width: 14, height: 14)
                                }
                                Spacer()
                            }
                            .padding(.top, 8)
                            .frame(width: 26)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .transition(.move(edge: .leading))
                        }
                        canvas
                        if demo.showsInspector {
                            VStack(alignment: .leading, spacing: 6) {
                                let panels = InspectorViewController.tabbedPanels
                                Text(verbatim: panels.indices.contains(demo.panel) ? panels[demo.panel].titleString : "")
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                ForEach(0..<4, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: CGFloat(70 - index * 10), height: 6)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .frame(width: 110, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .transition(.move(edge: .trailing))
                        }
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(.rect(cornerRadius: full ? 0 : 8))
                .shadow(color: .black.opacity(full ? 0 : 0.2), radius: 6, y: 2)

                if demo.showsFonts { floatingPanel("textformat", x: frame.width - 150, y: 40) }
                if demo.showsColors { floatingPanel("paintpalette", x: frame.width - 100, y: 90) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                landscape
                    .frame(width: proxy.size.width * 0.7, height: proxy.size.height * 0.7)
                    .scaleEffect(demo.zoom)
                    .offset(demo.pan)
                if demo.showsRulers { rulers(proxy.size) }
                if demo.isHoldingSpace {
                    Image(systemName: dragStart == nil ? "hand.raised" : "hand.raised.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .clipped()
            .contentShape(.rect)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard demo.isHoldingSpace else { return }
                        let start = dragStart ?? demo.pan
                        dragStart = start
                        demo.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
    }

    private var landscape: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.cyan.opacity(0.6), .orange.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            Circle().fill(.yellow.opacity(0.9)).frame(width: 26).offset(x: 30, y: -60)
            Ellipse().fill(.green.opacity(0.7)).frame(height: 70).offset(x: -40, y: 30)
            Ellipse().fill(.green).frame(height: 60).offset(x: 50, y: 34)
        }
        .clipped()
    }

    private func rulers(_ size: CGSize) -> some View {
        Canvas { context, size in
            let band: CGFloat = 12
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: band)), with: .color(Color(nsColor: .windowBackgroundColor)))
            context.fill(Path(CGRect(x: 0, y: 0, width: band, height: size.height)), with: .color(Color(nsColor: .windowBackgroundColor)))
            let spacing = 10 * demo.zoom
            var x = band + demo.pan.width.truncatingRemainder(dividingBy: spacing)
            var tick = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: tick % 5 == 0 ? 2 : 7, width: 0.5, height: band)), with: .color(.secondary))
                x += spacing
                tick += 1
            }
            var y = band + demo.pan.height.truncatingRemainder(dividingBy: spacing)
            tick = 0
            while y < size.height {
                context.fill(Path(CGRect(x: tick % 5 == 0 ? 2 : 7, y: y, width: band, height: 0.5)), with: .color(.secondary))
                y += spacing
                tick += 1
            }
        }
        .allowsHitTesting(false)
    }

    private func floatingPanel(_ symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(width: 90, height: 70)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .offset(x: x, y: y)
            .transition(.scale.combined(with: .opacity))
    }
}

private struct DocumentsDemo: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Shortcuts.DocumentsDemo")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
