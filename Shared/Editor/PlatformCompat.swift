import SwiftUI

/// The few places the editor's views differ between iPhone, iPad and Mac,
/// so the views themselves read the same everywhere.
extension Color {
    /// What the canvas sits on, around the picture.
    static var workspace: Color {
        #if os(iOS)
        Color(.secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

/// The keyboard a number field brings up on iPhone and iPad; a Mac's own
/// keyboard is always there.
enum NumberKeyboard {
    case integer, decimal, signed

    #if os(iOS)
    var keyboardType: UIKeyboardType {
        switch self {
        case .integer: .numberPad
        case .decimal: .decimalPad
        case .signed: .numbersAndPunctuation
        }
    }
    #endif
}

extension ToolbarItemPlacement {
    /// The leading end of a sheet's bar on iPhone and iPad; on the Mac, the
    /// sheet's main button.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .primaryAction
        #endif
    }

    /// The trailing end of a sheet's bar on iPhone and iPad; on the Mac, the
    /// button that dismisses the sheet.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .cancellationAction
        #endif
    }
}

extension View {
    /// A small title in the bar, where the system would otherwise make a
    /// large one.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func numberKeyboard(_ keyboard: NumberKeyboard) -> some View {
        #if os(iOS)
        keyboardType(keyboard.keyboardType)
        #else
        self
        #endif
    }

    /// The look of the lists in the editor's panels: inset, grouped rows
    /// on iPhone and iPad, an inset list on the Mac.
    func panelListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}
