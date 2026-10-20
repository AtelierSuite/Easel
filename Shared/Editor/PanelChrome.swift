import Paintbrush
import SwiftUI

/// Where a panel is showing, which decides where its Cancel and Done go.
enum PanelPlacement {
    /// A sheet on iPhone, inside a navigation stack with a toolbar of its own.
    case sheet
    /// The inspector beside the canvas on iPad and the Mac, which has no
    /// toolbar to offer: the window's belongs to the document.
    case inspector
}

extension PanelPlacement {
    /// Whether a panel that would try its change out until it is confirmed
    /// keeps it on the layer as a filter as it is made instead, undone from
    /// the history: in the Mac's inspector, which has no Done to wait for.
    var keepsChangesLive: Bool {
        #if os(macOS)
        self == .inspector
        #else
        false
        #endif
    }
}

extension PanelPlacement {
    /// Whether the panel is in the Mac's inspector, which is laid out like
    /// those in Pages, Numbers and Keynote rather than like iPad's.
    var isMacInspector: Bool {
        #if os(macOS)
        self == .inspector
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    @Entry var panelPlacement: PanelPlacement = .sheet
    @Entry var panelTitle: LocalizedStringKey = ""
}

extension View {
    /// Gives a panel its Cancel and Done buttons, wherever it is showing.
    func panelActions(
        cancel: (() -> Void)? = nil, confirm: (() -> Void)? = nil, confirmDisabled: Bool = false,
        confirmIdentifier: String? = nil
    ) -> some View {
        modifier(PanelActions(
            cancel: cancel, confirm: confirm, confirmDisabled: confirmDisabled, confirmIdentifier: confirmIdentifier
        ))
    }
}

private struct PanelActions: ViewModifier {
    let cancel: (() -> Void)?
    let confirm: (() -> Void)?
    let confirmDisabled: Bool
    let confirmIdentifier: String?
    @Environment(\.panelPlacement) private var placement
    @Environment(\.panelTitle) private var title

    func body(content: Content) -> some View {
        switch placement {
        case .sheet:
            content.toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel, action: cancel)
                    }
                }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm, action: confirm)
                            .disabled(confirmDisabled)
                            .accessibilityIdentifier(confirmIdentifier ?? "panelConfirm")
                    }
                }
            }
        case .inspector:
            #if os(macOS)
            // As a Mac inspector: its tab names the panel, and only a panel
            // with no tab, such as Image Size, has a title of its own.
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if cancel != nil {
                        Text(title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // A panel that can only be closed has nothing to put
                    // here: what it changes already took effect, and is in
                    // the history to undo. Only a panel trying a change out
                    // on the canvas has one to keep or throw away.
                    if cancel != nil {
                        HStack(spacing: 8) {
                            Spacer()
                            if let cancel {
                                Button("Common.Cancel", role: .cancel, action: cancel)
                            }
                            if let confirm {
                                Button("Common.Done", action: confirm)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(confirmDisabled)
                                    .accessibilityIdentifier(confirmIdentifier ?? "panelConfirm")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.bar)
                    }
                }
            #else
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 12) {
                    if let cancel {
                        Button(role: .cancel, action: cancel) {
                            Label("Common.Cancel", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    }
                    Text(title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: cancel == nil ? .leading : .center)
                    if let confirm {
                        Button(role: .confirm, action: confirm)
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .disabled(confirmDisabled)
                            .accessibilityIdentifier(confirmIdentifier ?? "panelConfirm")
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            #endif
        }
    }
}
