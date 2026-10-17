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

    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

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
#endif
