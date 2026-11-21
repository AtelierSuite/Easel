import Foundation

public struct UTType: Hashable, Sendable, CustomStringConvertible {
    public let identifier: String
    public let preferredFilenameExtension: String?
    public let preferredMIMEType: String?

    public init(_ identifier: String) {
        self.init(identifier: identifier, extension: nil, mime: nil)
    }

    init(identifier: String, extension: String?, mime: String?) {
        self.identifier = identifier
        preferredFilenameExtension = `extension`
        preferredMIMEType = mime
    }

    public init?(filenameExtension: String) {
        guard let known = Self.known.first(where: { $0.preferredFilenameExtension == filenameExtension.lowercased() }) else { return nil }
        self = known
    }

    public init?(mimeType: String) {
        guard let known = Self.known.first(where: { $0.preferredMIMEType == mimeType }) else { return nil }
        self = known
    }

    public var description: String { identifier }

    public func conforms(to type: UTType) -> Bool {
        if self == type { return true }
        if type == .image { return Self.images.contains(self) }
        if type == .data || type == .item { return true }
        return false
    }

    public static let png = UTType(identifier: "public.png", extension: "png", mime: "image/png")
    public static let jpeg = UTType(identifier: "public.jpeg", extension: "jpeg", mime: "image/jpeg")
    public static let heic = UTType(identifier: "public.heic", extension: "heic", mime: "image/heic")
    public static let heif = UTType(identifier: "public.heif", extension: "heif", mime: "image/heif")
    public static let tiff = UTType(identifier: "public.tiff", extension: "tiff", mime: "image/tiff")
    public static let gif = UTType(identifier: "com.compuserve.gif", extension: "gif", mime: "image/gif")
    public static let webP = UTType(identifier: "org.webmproject.webp", extension: "webp", mime: "image/webp")
    public static let bmp = UTType(identifier: "com.microsoft.bmp", extension: "bmp", mime: "image/bmp")
    public static let pdf = UTType(identifier: "com.adobe.pdf", extension: "pdf", mime: "application/pdf")
    public static let svg = UTType(identifier: "public.svg-image", extension: "svg", mime: "image/svg+xml")
    public static let json = UTType(identifier: "public.json", extension: "json", mime: "application/json")
    public static let zip = UTType(identifier: "public.zip-archive", extension: "zip", mime: "application/zip")
    public static let image = UTType(identifier: "public.image", extension: nil, mime: nil)
    public static let data = UTType(identifier: "public.data", extension: nil, mime: nil)
    public static let item = UTType(identifier: "public.item", extension: nil, mime: nil)
    public static let package = UTType(identifier: "com.apple.package", extension: nil, mime: nil)

    static let images: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .webP, .bmp, .image]
    static let known: [UTType] = images + [.pdf, .svg, .json, .zip, UTType(identifier: "public.jpeg", extension: "jpg", mime: "image/jpeg")]
}
