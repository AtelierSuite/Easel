import AppKit
import Paintbrush
import SwiftUI

/// The panels beside the canvas: a row of tabs along the top, as in other
/// Mac inspectors, and the panel picked below them.
@MainActor
final class InspectorViewController: NSViewController {
    private let session: EditorSession
    private var tabs: NSSegmentedControl!

    /// The panels with a tab. Image Size has none: it comes up from the
    /// Image menu, with Cancel and Done of its own.
    static let tabbedPanels: [EditorPanel] = [
        .layers, .adjustments, .filters, .effects, .looks, .text, .history, .comps, .artboards,
    ]

    init(session: EditorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let images = Self.tabbedPanels.map { panel in
            NSImage(systemSymbolName: panel.symbolName, accessibilityDescription: nil) ?? NSImage()
        }
        tabs = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(pickPanel(_:)))
        tabs.segmentStyle = .automatic
        tabs.segmentDistribution = .fillEqually
        for (index, panel) in Self.tabbedPanels.enumerated() {
            tabs.setToolTip(panel.titleString, forSegment: index)
            tabs.setWidth(0, forSegment: index)
        }
        tabs.setAccessibilityIdentifier("inspectorTabs")
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let content = NSHostingView(rootView: InspectorContent(state: session.state, history: session.history))
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeChanges { [weak self] in self?.showPanel() }
    }

    private func showPanel() {
        let panel = session.state.presentedPanel ?? .layers
        tabs.selectedSegment = Self.tabbedPanels.firstIndex(of: panel) ?? -1
    }

    @objc private func pickPanel(_ sender: NSSegmentedControl) {
        guard Self.tabbedPanels.indices.contains(sender.selectedSegment) else { return }
        session.state.presentedPanel = Self.tabbedPanels[sender.selectedSegment]
    }
}

/// The panel picked, laid out for the inspector.
private struct InspectorContent: View {
    let state: EditorState
    let history: CompositionHistory

    var body: some View {
        let panel = state.presentedPanel ?? .layers
        EditorPanelContent(panel: panel, state: state, history: history)
            .environment(\.panelPlacement, .inspector)
            .environment(\.panelTitle, panel.title)
            .id(panel)
    }
}

extension EditorPanel {
    /// The panel's name, looked up, for places that take a string.
    var titleString: String {
        switch self {
        case .layers: String(localized: "Panel.Layers.Title")
        case .adjustments: String(localized: "Panel.Adjustments.Title")
        case .filters: String(localized: "Panel.Filters.Title")
        case .effects: String(localized: "Panel.Effects.Title")
        case .looks: String(localized: "Panel.Looks.Title")
        case .text: String(localized: "Panel.Text.Title")
        case .imageSize: String(localized: "Panel.ImageSize.Title")
        case .history: String(localized: "Panel.History.Title")
        case .comps: String(localized: "Panel.Comps.Title")
        case .artboards: String(localized: "Panel.Artboards.Title")
        }
    }
}
