import Paintbrush
import SwiftUI

/// Where a panel is showing, which decides where its Cancel and Done go.
enum PanelPlacement {
    /// A sheet on iPhone, inside a navigation stack with a toolbar of its own.
    case sheet
    /// The inspector beside the canvas on iPad, which has no toolbar to
    /// offer: the window's belongs to the document.
    case inspector
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
        }
    }
}
