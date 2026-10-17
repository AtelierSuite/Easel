@preconcurrency import Photos
import Paintbrush
import PhotosUI
import SwiftUI
import UIKit

/// Easel inside the Photos app: picked from a photo's Edit menu, it opens the
/// full editor on the photo, and Done saves the edit back onto it — layers
/// included, so they are there again the next time.
final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private let model = PhotoEditingModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: PhotoEditingRoot(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        PhotoEditingSession.canHandle(adjustmentData)
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: UIImage) {
        let model = model
        Task { @MainActor in
            do {
                let session = try await PhotoEditingSession.load(contentEditingInput)
                model.start(session)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        let model = model
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in
            guard let session = model.session, let composition = model.composition else {
                completionHandler(nil)
                return
            }
            let output = try? await session.output(for: composition)
            // Photos saves the edit once it has the output; the layers of
            // the edit it replaces are no longer needed.
            if output != nil { PhotoEditPayload.discard(session.previousPayload) }
            completionHandler(output)
        }
    }

    var shouldShowCancelConfirmation: Bool {
        model.hasChanges
    }

    func cancelContentEditing() {
        model.session = nil
    }
}

/// The photo being edited, shared between the controller Photos talks to and
/// the editor on screen.
@MainActor
@Observable
final class PhotoEditingModel {
    var session: PhotoEditingSession?
    var composition: Composition?
    var loaded: Composition?
    var errorMessage: String?

    var hasChanges: Bool { composition != nil && composition != loaded }

    func start(_ session: PhotoEditingSession) {
        self.session = session
        composition = session.composition
        loaded = session.composition
    }
}

private struct PhotoEditingRoot: View {
    @Bindable var model: PhotoEditingModel

    var body: some View {
        NavigationStack {
            Group {
                if let composition = Binding($model.composition) {
                    EditorView(composition: composition)
                } else if let message = model.errorMessage {
                    ContentUnavailableView(
                        "Alert.Error.Title", systemImage: "exclamationmark.triangle", description: Text(message)
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
