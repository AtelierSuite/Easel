import AppKit
import Paintbrush

/// The tools in a capsule of glass floating down the canvas's left side,
/// grouped as on iPad: arranging, painting, retouching, adding. The tool in
/// hand stays lit.
@MainActor
final class ToolPaletteViewController: NSViewController {
    private let state: EditorState
    private var buttons: [Tool: NSButton] = [:]

    static let width: CGFloat = 44

    init(state: EditorState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        for (index, tools) in Tool.groups.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.widthAnchor.constraint(equalToConstant: 24).isActive = true
                stack.addArrangedSubview(separator)
                stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                stack.setCustomSpacing(8, after: separator)
            }
            for tool in tools {
                let button = toolButton(for: tool)
                buttons[tool] = button
                stack.addArrangedSubview(button)
            }
        }

        // Short windows scroll the capsule rather than cut it off.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.width / 2
        glass.contentView = scroll
        // As tall as the tools, unless the window is shorter.
        let fitsTools = glass.heightAnchor.constraint(equalTo: document.heightAnchor)
        fitsTools.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            glass.widthAnchor.constraint(equalToConstant: Self.width),
            fitsTools,
        ])
        view = glass
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in self?.showTool() }
    }

    private func toolButton(for tool: Tool) -> NSButton {
        let name = String(localized: String.LocalizationValue(tool.labelKey))
        let image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let button = ToolButton(image: image ?? NSImage(), target: self, action: #selector(pickTool(_:)))
        button.tag = Tool.allCases.firstIndex(of: tool) ?? 0
        button.toolTip = "\(name) (\(String(tool.shortcut.character).uppercased()))"
        button.setAccessibilityIdentifier("tool.\(tool.rawValue)")
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    private func showTool() {
        let current = state.tool
        for (tool, button) in buttons {
            let isOn = tool == current
            button.state = isOn ? .on : .off
            button.contentTintColor = isOn ? .controlAccentColor : nil
        }
    }

    @objc private func pickTool(_ sender: NSButton) {
        state.tool = Tool.allCases[sender.tag]
        // Clicking an already lit button would unlight it.
        showTool()
    }
}

/// A tool's button: its symbol, on a circle that shows under the pointer
/// and stays, tinted, while the tool is in hand.
private final class ToolButton: NSButton {
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    /// The frame is the circle: a button's own insets would make it taller
    /// than the square it is laid out in.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.pushOnPushOff)
        isBordered = false
        imagePosition = .imageOnly
        // At its own size: the square frame would stretch it to fill.
        imageScaling = .scaleNone
        // The circle shows the state and the press, not the cell.
        if let cell = cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = if state == .on {
            .controlAccentColor.withAlphaComponent(isHighlighted ? 0.3 : 0.2)
        } else if isHighlighted {
            .labelColor.withAlphaComponent(0.16)
        } else if isHovered {
            .labelColor.withAlphaComponent(0.08)
        } else {
            nil
        }
        if let fill {
            fill.setFill()
            // A circle, whatever shape the stack leaves the button.
            let diameter = min(bounds.width, bounds.height)
            NSBezierPath(ovalIn: NSRect(
                x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter
            )).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A view whose content starts at the top, for a scroll view's document.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
