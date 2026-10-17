import Paintbrush
import SwiftUI
import UIKit

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
