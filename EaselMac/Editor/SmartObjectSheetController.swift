import AppKit
import Paintbrush

/// A smart object's contents open in an editor of their own, in a sheet
/// over the document; Done puts them back into the layer, drawn out afresh.
@MainActor
final class SmartObjectSheetController: NSWindowController {
    private let parent: EditorState
    private let layerID: Layer.ID
    private let original: Composition
    private var contents: Composition
    private let session: EditorSession
    private let finished: () -> Void

    init(parent: EditorState, layerID: Layer.ID, finished: @escaping () -> Void) {
        self.parent = parent
        self.layerID = layerID
        let contents = parent.composition[layerID]?.smartObject?.contents ?? .blank()
        original = contents
        self.contents = contents
        self.finished = finished
        var publish: (Composition) -> Void = { _ in /* Replaced below. */ }
        session = EditorSession(composition: contents) { publish($0) }

        let name = parent.composition[layerID]?.name ?? ""
        let editor = EditorViewController(session: session) { name }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 760, height: 520)
        super.init(window: window)

        let container = NSViewController()
        container.view = NSView()
        container.addChild(editor)
        let bar = buttonBar()
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(editor.view)
        container.view.addSubview(bar)
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            editor.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: editor.view.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            container.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            container.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        window.contentViewController = container
        window.setContentSize(NSSize(width: 1100, height: 720))
        publish = { [weak self] in self?.contents = $0 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The name, and Cancel and Done, along the sheet's bottom.
    private func buttonBar() -> NSView {
        let title = NSTextField(labelWithString: parent.composition[layerID]?.name ?? "")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: String(localized: "Common.Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: String(localized: "Common.Done"), target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("finishSmartObject")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [title, spacer, cancel, done])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.spacing = 12
        return stack
    }

    @objc private func cancel(_ sender: Any?) {
        guard contents != original, let window else { return close() }
        let alert = NSAlert()
        alert.messageText = String(localized: "SmartObject.Discard")
        alert.addButton(withTitle: String(localized: "PhotoEditor.Discard.Confirm"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close() }
        }
    }

    @objc private func done(_ sender: Any?) {
        if contents != original { parent.updateSmartObject(layerID, contents: contents) }
        close()
    }

    override func close() {
        if let window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
        finished()
    }
}
