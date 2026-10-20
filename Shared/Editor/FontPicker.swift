import Paintbrush
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
/// The system's font picker, handing back the family picked.
struct FontPicker: UIViewControllerRepresentable {
    let picked: (String) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {
        context.coordinator.picked = picked
    }

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        var picked: (String) -> Void

        init(picked: @escaping (String) -> Void) {
            self.picked = picked
        }

        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            guard let descriptor = picker.selectedFontDescriptor else { return }
            let family = descriptor.object(forKey: .family) as? String
                ?? UIFont(descriptor: descriptor, size: 12).familyName
            picked(family)
        }
    }
}
#else
/// The installed font families, each shown in its own face, handing back
/// the family picked.
struct FontPicker: View {
    let picked: (String) -> Void
    @State private var search = ""

    static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    private var shown: [String] {
        search.isEmpty ? Self.families : Self.families.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(shown, id: \.self) { family in
            Button {
                picked(family)
            } label: {
                Text(verbatim: family)
                    .font(.custom(family, size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $search, placement: .toolbar)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 420, idealHeight: 520)
    }
}

/// The Mac's Fonts window, which sets the active text layer's family, size
/// and weight as they are picked in it.
@MainActor
final class FontPanelBridge: NSObject {
    static let shared = FontPanelBridge()
    private weak var state: EditorState?

    func show(for state: EditorState) {
        self.state = state
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        if let font = currentFont { manager.setSelectedFont(font, isMultiple: false) }
        manager.orderFrontFontPanel(self)
    }

    /// The text layer's font as the Fonts window knows fonts.
    private var currentFont: NSFont? {
        guard let text = state?.activeLayer?.text else { return nil }
        var traits: NSFontTraitMask = []
        if text.isBold { traits.insert(.boldFontMask) }
        if text.isItalic { traits.insert(.italicFontMask) }
        let manager = NSFontManager.shared
        if let family = text.fontName,
           let font = manager.font(withFamily: family, traits: traits, weight: 5, size: text.fontSize) {
            return font
        }
        return manager.convert(NSFont.systemFont(ofSize: text.fontSize), toHaveTrait: traits)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let state, state.activeLayer?.text != nil else { return }
        let manager = NSFontManager.shared
        let font = manager.convert(currentFont ?? NSFont.systemFont(ofSize: 12))
        let traits = manager.traits(of: font)
        // The system font's family is hidden, and is kept as no family at all.
        let family = font.familyName.flatMap { $0.hasPrefix(".") ? nil : $0 }
        state.updateText { text in
            text.fontName = family
            text.fontSize = font.pointSize
            text.isBold = traits.contains(.boldFontMask)
            text.isItalic = traits.contains(.italicFontMask)
        }
    }
}
#endif
