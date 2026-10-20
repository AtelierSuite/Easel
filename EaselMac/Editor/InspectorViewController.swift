import AppKit
import Paintbrush
import SwiftUI

/// The panels beside the canvas, after the inspectors in Pages, Numbers and
/// Keynote: a page for the picked layer and one for the whole document,
/// picked in the toolbar, each with a row of named tabs along its top.
@MainActor
final class InspectorViewController: NSViewController {
    private let session: EditorSession
    private var tabs: NSSegmentedControl!
    private var shownTabs: [EditorPanel] = []

    /// The panels for the picked layer. Looks share Adjust's tab, and Text
    /// shows only while there is text to set, as a table's tabs do in Numbers.
    static let formatPanels: [EditorPanel] = [.layers, .adjustments, .filters, .effects, .text]
    /// The panels for the document as a whole.
    static let documentPanels: [EditorPanel] = [.history, .comps, .artboards]
    /// Every panel with a tab, in the order the View menu lists them. Image
    /// Size has none: it comes up from the Image menu, with Cancel and Done
    /// of its own.
    static let tabbedPanels = formatPanels + documentPanels

    init(session: EditorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        tabs = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(pickPanel(_:)))
        tabs.segmentStyle = .automatic
        tabs.segmentDistribution = .fillEqually
        tabs.setAccessibilityIdentifier("inspectorTabs")
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let content = NSHostingView(rootView: InspectorContent(state: session.state, history: session.history))
        // The panels scroll; left to size the window by their content, a
        // long one would hold the window taller than it is and push the
        // canvas's bars off its bottom.
        content.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
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
        let state = session.state
        let panel = (state.presentedPanel ?? .layers).inspectorPanel
        let page = Self.documentPanels.contains(panel) ? Self.documentPanels : Self.formatPanels
        let hasText = state.activeLayer?.isText == true || panel == .text
        let shown = page.filter { $0 != .text || hasText }
        if shown != shownTabs {
            shownTabs = shown
            tabs.segmentCount = shown.count
            for (index, tab) in shown.enumerated() {
                tabs.setLabel(tab.tabTitle, forSegment: index)
                tabs.setToolTip(tab.titleString, forSegment: index)
                tabs.setWidth(0, forSegment: index)
            }
        }
        tabs.selectedSegment = shown.firstIndex(of: panel) ?? -1
    }

    @objc private func pickPanel(_ sender: NSSegmentedControl) {
        guard shownTabs.indices.contains(sender.selectedSegment) else { return }
        session.state.presentedPanel = shownTabs[sender.selectedSegment]
    }
}

extension EditorPanel {
    /// The panel that shows this one in the Mac's inspector, where Looks
    /// sit at the top of Adjust.
    var inspectorPanel: EditorPanel { self == .looks ? .adjustments : self }

    /// The panel's name on its tab, shortened where the full one would not
    /// fit beside the others.
    var tabTitle: String {
        switch self {
        case .effects: String(localized: "Inspector.Tab.Styles")
        case .comps: String(localized: "Inspector.Tab.Comps")
        default: titleString
        }
    }
}

/// The panel picked, laid out for the inspector.
private struct InspectorContent: View {
    let state: EditorState
    let history: CompositionHistory

    var body: some View {
        let panel = (state.presentedPanel ?? .layers).inspectorPanel
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

/// A page of the inspector, picked in the toolbar: the picked layer's
/// settings, or the document's.
@MainActor
enum InspectorPage: CaseIterable {
    case format, document

    init(_ panel: EditorPanel) {
        self = InspectorViewController.documentPanels.contains(panel) ? .document : .format
    }

    var label: String {
        switch self {
        case .format: String(localized: "Inspector.Format")
        case .document: String(localized: "Inspector.Document")
        }
    }

    var symbolName: String {
        switch self {
        case .format: "paintbrush"
        case .document: "doc.text"
        }
    }
}
