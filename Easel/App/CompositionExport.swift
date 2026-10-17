import CoreTransferable
import Paintbrush
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Wraps a composition so it can be handed to `ShareLink`, written only
/// once a destination is picked.
struct CompositionExport: Transferable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case png, jpeg, heic, psd, svg, pdf, easel

        var id: String { rawValue }

        var contentType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .psd: return .photoshopImage
            case .svg: return .svg
            case .pdf: return .pdf
            case .easel: return .easelImage
            }
        }

        var pathExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .psd: return "psd"
            case .svg: return "svg"
            case .pdf: return "pdf"
            case .easel: return "easel"
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .png: return "Export.PNG"
            case .jpeg: return "Export.JPEG"
            case .heic: return "Export.HEIC"
            case .psd: return "Export.PSD"
            case .svg: return "Export.SVG"
            case .pdf: return "Export.PDF"
            case .easel: return "Export.Easel"
            }
        }
    }

    var composition: Composition
    var name: String
    var format: Format

    static var transferRepresentation: some TransferRepresentation {
        representation(for: .png)
        representation(for: .jpeg)
        representation(for: .heic)
        representation(for: .psd)
        representation(for: .svg)
        representation(for: .pdf)
        representation(for: .easel)
    }

    private static func representation(for format: Format) -> some TransferRepresentation<CompositionExport> {
        FileRepresentation(exportedContentType: format.contentType) { export in
            SentTransferredFile(try export.write())
        }
        .suggestedFileName { "\($0.name).\(format.pathExtension)" }
        .exportingCondition { $0.format == format }
    }

    private func write() throws -> URL {
        // A per-export folder keeps concurrent shares from colliding on name.
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(sanitizedName).\(format.pathExtension)")
        if format == .easel {
            try CompositionArchive.fileWrapper(for: composition).write(to: url, originalContentsURL: nil)
        } else if format == .psd {
            try PSDWriter.data(for: composition).write(to: url, options: .atomic)
        } else if format == .svg {
            try SVGWriter.data(for: composition).write(to: url, options: .atomic)
        } else if format == .pdf {
            try PDFWriter.data(for: composition).write(to: url, options: .atomic)
        } else {
            try ImageCodec.encode(CompositionRenderer.render(composition), as: format.contentType)
                .write(to: url, options: .atomic)
        }
        return url
    }

    private var sanitizedName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? String(localized: "Export.DefaultName") : cleaned
    }

    /// Adds the flattened picture to the photo library as a new photo.
    @concurrent
    static func saveToPhotos(_ composition: Composition) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.accessDenied }
        let data = try ImageCodec.encode(CompositionRenderer.render(composition), as: .heic)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

enum PhotoLibraryError: LocalizedError {
    case accessDenied
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied: return String(localized: "Error.PhotosAccessDenied")
        case .assetUnavailable: return String(localized: "Error.PhotoUnavailable")
        }
    }
}
