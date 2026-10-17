import AppIntents
import CoreGraphics
import Foundation
import Paintbrush
import UniformTypeIdentifiers

/// The file formats a Shortcuts action can write.
enum ImageFileFormat: String, AppEnum {
    case png, jpeg, heic, psd

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent.Format.Type")
    static let caseDisplayRepresentations: [ImageFileFormat: DisplayRepresentation] = [
        .png: DisplayRepresentation(title: "Export.PNG"),
        .jpeg: DisplayRepresentation(title: "Export.JPEG"),
        .heic: DisplayRepresentation(title: "Export.HEIC"),
        .psd: DisplayRepresentation(title: "Export.PSD"),
    ]

    var format: CompositionExport.Format {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .psd: return .psd
        }
    }
}

extension IntentFile {
    /// The picture in the file.
    func image() throws -> CGImage {
        try ImageAutomation.image(from: data, filename: filename)
    }

    /// A file holding `image`, named after this one.
    func replacing(with image: CGImage, as format: CompositionExport.Format, quality: Double = 0.92) throws -> IntentFile {
        IntentFile(
            data: try ImageAutomation.data(for: image, as: format, quality: quality),
            filename: ImageAutomation.filename(filename, as: format), type: format.contentType
        )
    }

    /// The format the file is in, or PNG for anything Easel cannot write.
    var writableFormat: CompositionExport.Format {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "psd": return .psd
        default: return .png
        }
    }
}

struct ResizeImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Resize.Title"
    static let description = IntentDescription("Intent.Resize.Description")

    @Parameter(title: "Intent.Parameter.Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Intent.Parameter.Width", inclusiveRange: (1, 8192))
    var width: Int?

    @Parameter(title: "Intent.Parameter.Height", inclusiveRange: (1, 8192))
    var height: Int?

    @Parameter(title: "Intent.Parameter.KeepProportions", default: true)
    var keepsProportions: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Resize.Summary \(\.$image) \(\.$width) \(\.$height)") {
            \.$keepsProportions
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let resized = try ImageAutomation.resize(
            try image.image(), width: width, height: height, keepsProportions: keepsProportions
        )
        return .result(value: try image.replacing(with: resized, as: image.writableFormat))
    }
}

struct ConvertImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.Convert.Title"
    static let description = IntentDescription("Intent.Convert.Description")

    @Parameter(title: "Intent.Parameter.Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Intent.Parameter.Format", default: .jpeg)
    var format: ImageFileFormat

    @Parameter(title: "Intent.Parameter.Quality", default: 0.9, inclusiveRange: (0.1, 1))
    var quality: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.Convert.Summary \(\.$image) \(\.$format)") {
            \.$quality
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        .result(value: try image.replacing(with: try image.image(), as: format.format, quality: quality))
    }
}

struct RemoveBackgroundIntent: AppIntent {
    static let title: LocalizedStringResource = "Intent.RemoveBackground.Title"
    static let description = IntentDescription("Intent.RemoveBackground.Description")

    @Parameter(title: "Intent.Parameter.Image", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Intent.RemoveBackground.Summary \(\.$image)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let cutOut = try ImageAutomation.removingBackground(from: try image.image())
        // PNG, which keeps the transparency.
        return .result(value: try image.replacing(with: cutOut, as: .png))
    }
}

/// The actions Siri and Spotlight offer by phrase, without a shortcut being
/// built first.
struct EaselShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RemoveBackgroundIntent(),
            phrases: ["Remove the background with \(.applicationName)", "Cut out a subject with \(.applicationName)"],
            shortTitle: "Intent.RemoveBackground.Title",
            systemImageName: "person.and.background.dotted"
        )
        AppShortcut(
            intent: ResizeImageIntent(),
            phrases: ["Resize an image with \(.applicationName)"],
            shortTitle: "Intent.Resize.Title",
            systemImageName: "arrow.up.left.and.arrow.down.right"
        )
        AppShortcut(
            intent: ConvertImageIntent(),
            phrases: ["Convert an image with \(.applicationName)"],
            shortTitle: "Intent.Convert.Title",
            systemImageName: "photo.on.rectangle.angled"
        )
    }
}
