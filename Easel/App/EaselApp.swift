import Paintbrush
import SwiftUI

@main
struct EaselApp: App {
    @State private var photoEditLauncher = PhotoEditLauncher()

    var body: some Scene {
        DocumentGroup(newDocument: EaselDocument()) { configuration in
            DocumentView(document: configuration.$document, fileURL: configuration.fileURL)
        }

        // An empty title, so the painting carries the header on its own.
        // With no title at all, the scene falls back to the app's name.
        DocumentGroupLaunchScene(Text(verbatim: "")) {
            NewDocumentButton("Launch.NewImage")
            // A new image made from the picture on the clipboard. With
            // nothing there, no document is made and the launch screen says so.
            NewDocumentButton(Text("Launch.FromClipboard"), for: EaselDocument.self) { @MainActor in
                guard let item = ImageImport.pasteboardImage() else {
                    photoEditLauncher.errorMessage = String(localized: "Error.NothingToPaste")
                    return nil
                }
                return EaselDocument(composition: Composition(
                    image: item.image, name: String(localized: "Layer.DefaultName.Background")
                ))
            }
            .accessibilityIdentifier("newFromClipboard")
            // Text only: with an icon, the scene splits the label into two
            // actions and tucks them behind a "Show More" menu, the icon's empty.
            Button("Launch.EditPhoto") {
                photoEditLauncher.isPicking = true
            }
            .accessibilityIdentifier("editPhoto")
        } background: {
            DocumentLaunchBackground()
                .modifier(PhotoEditPresenter(launcher: photoEditLauncher))
        } backgroundAccessoryView: { geometry in
            DocumentLaunchPainting(geometry: geometry)
        }
    }
}
