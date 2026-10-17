@preconcurrency import Photos
import Paintbrush
import PhotosUI
import SwiftUI

/// Opens a photo from the library and saves the edit back onto it, the way
/// Photos' own editor does: the original is kept, the edit can be reverted
/// from Photos, and Easel's layers come back the next time it is opened here.
struct PhotoLibraryEditor: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss

    @State private var session: PhotoEditingSession?
    @State private var composition = Composition.blank()
    @State private var loaded: Composition?
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var errorMessage: String?
    /// Set once loading starts: the cover can appear twice as it settles,
    /// and a second load would replace the photo under the editor.
    @State private var hasStartedLoading = false

    private var hasChanges: Bool { loaded != nil && composition != loaded }

    var body: some View {
        NavigationStack {
            Group {
                if session != nil {
                    EditorView(composition: $composition)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("PhotoEditor.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if hasChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog(
                        "PhotoEditor.Discard.Title", isPresented: $isConfirmingDiscard, titleVisibility: .visible
                    ) {
                        Button("PhotoEditor.Discard.Confirm", role: .destructive) { dismiss() }
                    }
                    .accessibilityIdentifier("cancelPhotoEdit")
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("PhotoEditor.Save", systemImage: "checkmark", role: .confirm) { save() }
                            .disabled(session == nil || !hasChanges)
                            .accessibilityIdentifier("savePhotoEdit")
                    }
                }
                if asset.hasAdjustments {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("PhotoEditor.Revert", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                            revert()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
        .task { await load() }
        .alert(
            "Alert.Error.Title",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("Common.OK", role: .cancel) {
                errorMessage = nil
                if session == nil { dismiss() }
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        do {
            let input = try await Self.contentEditingInput(for: asset)
            let session = try await PhotoEditingSession.load(input)
            composition = session.composition
            loaded = session.composition
            self.session = session
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let session else { return }
        isSaving = true
        let composition = composition
        let asset = asset
        Task {
            do {
                let output = try await session.output(for: composition)
                do {
                    try await Self.apply(output, to: asset)
                } catch {
                    // Not saved: the copy just written is not needed.
                    PhotoEditPayload.discard(output.adjustmentData?.data)
                    throw error
                }
                // The edit it replaced no longer needs its layers kept.
                PhotoEditPayload.discard(session.previousPayload)
                dismiss()
            } catch {
                // Declining the system's "Allow Easel to modify this photo?"
                // lands here too, and the edit stays open to try again.
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func revert() {
        let asset = asset
        Task {
            do {
                try await Self.revert(asset)
                PhotoEditPayload.discard(session?.previousPayload)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // Off the main actor: Photos runs change blocks on a queue of its own,
    // and a block made on the main actor would trap there.
    @concurrent
    private static func apply(_ output: PHContentEditingOutput, to asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    @concurrent
    private static func revert(_ asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
        }
    }

    private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { PhotoEditingSession.canHandle($0) }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: PhotoLibraryError.assetUnavailable)
                }
            }
        }
    }
}

/// Opening a photo from the library to edit in place.
///
/// The launch screen may fold its extra actions into a menu, which goes
/// away the moment one is chosen, so the action only asks; the picker and
/// the editor are presented from the launch screen's background, which stays.
@MainActor
@Observable
final class PhotoEditLauncher {
    var isPicking = false
    var item: PhotosPickerItem?
    var asset: IdentifiedAsset?
    var errorMessage: String?

    struct IdentifiedAsset: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    /// Editing writes back to the library, so this asks for access to it first.
    func open(_ item: PhotosPickerItem) async {
        guard let identifier = item.itemIdentifier else {
            errorMessage = PhotoLibraryError.assetUnavailable.localizedDescription
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            errorMessage = PhotoLibraryError.accessDenied.localizedDescription
            return
        }
        guard let found = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            errorMessage = PhotoLibraryError.assetUnavailable.localizedDescription
            return
        }
        asset = IdentifiedAsset(asset: found)
    }
}

/// Hosts the photo picker and the photo editor for `PhotoEditLauncher`.
struct PhotoEditPresenter: ViewModifier {
    @Bindable var launcher: PhotoEditLauncher

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $launcher.isPicking, selection: $launcher.item,
                matching: .images, photoLibrary: .shared()
            )
            .onChange(of: launcher.item) { _, item in
                guard let item else { return }
                launcher.item = nil
                Task { await launcher.open(item) }
            }
            .fullScreenCover(item: $launcher.asset) { asset in
                PhotoLibraryEditor(asset: asset.asset)
            }
            .alert(
                "Alert.Error.Title",
                isPresented: Binding(
                    get: { launcher.errorMessage != nil }, set: { if !$0 { launcher.errorMessage = nil } }
                )
            ) {
                Button("Common.OK", role: .cancel) { launcher.errorMessage = nil }
            } message: {
                Text(launcher.errorMessage ?? "")
            }
    }
}
