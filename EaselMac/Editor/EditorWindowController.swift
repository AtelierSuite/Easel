import AppKit
import Paintbrush
import SwiftUI
import UniformTypeIdentifiers

/// A document's window: the editor, and the toolbar and File menu commands
/// that belong to the document — sharing, exporting, keeping layers.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let session: EditorSession
    private var smartObjectSheet: SmartObjectSheetController?

    private var imageDocument: ImageDocument? { document as? ImageDocument }

    init(document: ImageDocument) {
        let session = EditorSession(composition: document.composition) { [weak document] in
            document?.publish($0)
        }
        self.session = session
        let editor = EditorViewController(session: session) { [weak document] in
            document?.displayName ?? String(localized: "Export.DefaultName")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 820, height: 560)
        window.contentViewController = editor
        // The editor's views would size the window to their smallest.
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.tabbingMode = .automatic
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        document.compositionReplaced = { [weak session] in session?.state.sync($0) }
        if document.requiresCopyBeforeEditing {
            let losses = WriteBackLoss.allCases.filter(document.composition.writeBackLosses.contains)
            session.state.copyBeforeEditing = CopyBeforeEditing(
                isRequired: { [weak document] in document?.requiresCopyBeforeEditing ?? false },
                reasons: losses.map(\.label),
                save: { [weak document] completion in
                    guard let document else { return completion(false) }
                    document.saveCopy(completion: completion)
                }
            )
        }
        observeChanges { [weak self] in self?.followSmartObjectEditing() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { displayName }

    /// Undo and Redo in the toolbar follow the window that is in front.
    func windowDidBecomeKey(_ notification: Notification) {
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Smart objects

    /// Opens a smart object's contents in a sheet of their own when the
    /// editor asks to.
    private func followSmartObjectEditing() {
        let editing = session.state.editingSmartObject
        guard let editing, smartObjectSheet == nil, let window else { return }
        let sheet = SmartObjectSheetController(parent: session.state, layerID: editing.layerID) { [weak self] in
            self?.smartObjectSheet = nil
            self?.session.state.editingSmartObject = nil
        }
        smartObjectSheet = sheet
        window.beginSheet(sheet.window!)
    }

    // MARK: - File menu

    /// Exports the picture in the format a menu item's tag picks out of
    /// `CompositionExport.Format`, to a file chosen in a Save panel.
    @objc func exportAs(_ sender: NSMenuItem) {
        guard CompositionExport.Format.allCases.indices.contains(sender.tag), let window else { return }
        let format = CompositionExport.Format.allCases[sender.tag]
        let export = CompositionExport(
            composition: session.state.composition, name: imageDocument?.displayName ?? "", format: format
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(export.sanitizedName).\(format.pathExtension)"
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Self.write(export, to: url)
                } catch {
                    self?.session.state.errorMessage = error.localizedDescription
                }
            }
        }
    }

    @concurrent
    private static func write(_ export: CompositionExport, to url: URL) async throws {
        try export.write(to: url)
    }

    @objc func exportWithPresets(_ sender: Any?) {
        session.sheets.isExportingWithPresets = true
    }

    /// Saves a plain picture, flattened when saved, as an Easel image that
    /// keeps its layers.
    @objc func convertToEasel(_ sender: Any?) {
        imageDocument?.convertToEasel()
    }

    private var canConvert: Bool {
        guard let url = imageDocument?.fileURL else { return false }
        return DocumentConversion.canConvert(url)
    }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(convertToEasel(_:)): canConvert
        default: true
        }
    }
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let undoRedo = NSToolbarItem.Identifier("undoRedo")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let share = NSToolbarItem.Identifier("share")
    static let export = NSToolbarItem.Identifier("export")
    static let inspectorPages = NSToolbarItem.Identifier("inspectorPages")
}

extension EditorWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .undoRedo, .space, .zoom, .flexibleSpace,
         .export, .share, .inspectorTrackingSeparator, .flexibleSpace, .inspectorPages]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.undoRedo, .zoom, .export, .share,
         .inspectorTrackingSeparator, .inspectorPages, .toggleInspector, .space, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .undoRedo:
            let undo = button(.undoRedo, "Toolbar.Undo", "arrow.uturn.backward", #selector(EditorViewController.undo(_:)))
            let redo = button(.undoRedo, "Toolbar.Redo", "arrow.uturn.forward", #selector(EditorViewController.redo(_:)))
            let group = NSToolbarItemGroup(itemIdentifier: identifier)
            group.subitems = [undo, redo]
            group.label = String(localized: "Menu.UndoRedo")
            return group
        case .zoom:
            let out = button(.zoom, "Menu.ZoomOut", "minus.magnifyingglass", #selector(EditorViewController.zoomOut(_:)))
            let fit = button(.zoom, "Canvas.FitToScreen", "arrow.down.right.and.arrow.up.left", #selector(EditorViewController.zoomToFit(_:)))
            let zoomIn = button(.zoom, "Menu.ZoomIn", "plus.magnifyingglass", #selector(EditorViewController.zoomIn(_:)))
            let group = NSToolbarItemGroup(itemIdentifier: identifier)
            group.subitems = [out, fit, zoomIn]
            group.label = String(localized: "Menu.ZoomGroup")
            return group
        case .inspectorPages:
            // As in Pages, Numbers and Keynote: a button for each page of
            // the inspector, the one showing pressed in, which hides it.
            let pages = InspectorPage.allCases
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: pages.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.label)! },
                selectionMode: .selectOne,
                labels: pages.map(\.label),
                target: nil,
                action: #selector(EditorViewController.showInspectorPage(_:))
            )
            for (subitem, page) in zip(group.subitems, pages) { subitem.toolTip = page.label }
            group.label = String(localized: "Toolbar.Inspector")
            return group
        case .export:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            item.label = String(localized: "Menu.Export")
            item.toolTip = item.label
            item.menu = MainMenu.exportMenu()
            item.showsIndicator = true
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Toolbar.Share")
            item.toolTip = item.label
            item.delegate = self
            return item
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, _ label: String.LocalizationValue, _ symbol: String, _ action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: label)
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.action = action
        item.isBordered = true
        return item
    }
}

extension EditorWindowController: NSSharingServicePickerToolbarItemDelegate {
    /// The picture, flattened to a PNG named after the document. AppKit asks
    /// for the items whenever it checks the toolbar, so the file is only
    /// written once a service is picked.
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        let export = CompositionExport(
            composition: session.state.composition, name: imageDocument?.displayName ?? "", format: .png
        )
        let provider = NSItemProvider()
        provider.suggestedName = export.sanitizedName
        // Run off the main thread, when a service asks for the file.
        provider.registerFileRepresentation(for: .png, visibility: .all) { completion in
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
            let url = folder.appending(path: "\(export.sanitizedName).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try export.write(to: url)
                completion(url, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return [provider]
    }
}
