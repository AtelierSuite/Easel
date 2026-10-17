import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Brush tips made from pictures someone imported, kept as files shared
/// with the Photos editing extension.
package enum CustomBrushTips {
    /// The side of a tip's square image, in pixels, as the built-in tips.
    package static let size = 128

    package static var folder: URL? {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appending(path: "Brush Tips", directoryHint: .isDirectory)
    }

    private static func file(for id: UUID) -> URL? {
        folder?.appending(path: "\(id.uuidString).png")
    }

    /// The imported tips, oldest first.
    package static func saved() -> [UUID] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        let dated = files.compactMap { url -> (UUID, Date)? in
            guard url.pathExtension == "png", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (id, created)
        }
        return dated.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The tip's shape, white on clear, or nil if it is gone.
    package static func image(_ id: UUID) -> CGImage? {
        guard let url = file(for: id), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Makes `picture` a tip and keeps it, returning its id.
    package static func add(_ picture: CGImage) throws -> UUID {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        guard let url = file(for: id),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, shape(of: picture), nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return id
    }

    package static func delete(_ id: UUID) {
        guard let url = file(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The picture as a tip: fitted into a square, white where it paints.
    /// A picture with a see-through background paints where it is solid;
    /// an opaque one, such as a scan of a mark on paper, paints where it is
    /// dark.
    package static func shape(of picture: CGImage) -> CGImage {
        let side = Double(size)
        let scale = side / Double(max(picture.width, picture.height))
        let fitted = CGSize(width: Double(picture.width) * scale, height: Double(picture.height) * scale)
        let placed = Bitmap.render(size: CGSize(width: side, height: side)) { context in
            Bitmap.draw(picture, in: CGRect(
                x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height
            ), context: context)
        }
        guard let pixels = Bitmap.pixels(of: placed) else { return placed }
        let count = size * size
        // Opaque pictures fill the square, or the fitted part of it.
        let fittedArea = fitted.width * fitted.height
        let solid = (0..<count).filter { pixels.bytes[$0 * 4 + 3] > 250 }.count
        let usesDarkness = Double(solid) > fittedArea * 0.95
        var coverage = (0..<count).map { index -> Double in
            let color = pixels.color(x: index % size, y: index / size)
            let alpha = color.alpha / 255
            guard usesDarkness else { return alpha }
            let lightness = (0.299 * color.red + 0.587 * color.green + 0.114 * color.blue) / 255
            return (1 - lightness) * alpha
        }
        // The darkest mark paints fully, however faint the picture.
        let strongest = coverage.max() ?? 0
        if strongest > 0 { coverage = coverage.map { $0 / strongest } }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            let value = UInt8(min(max(coverage[index], 0), 1) * 255)
            for channel in 0..<4 { bytes[index * 4 + channel] = value }
        }
        return PixelBuffer(width: size, height: size, bytes: bytes).makeImage() ?? placed
    }
}

/// The imported tips for the brush settings to list, kept up to date as
/// they are added and deleted.
@MainActor
@Observable
package final class CustomBrushTipLibrary {
    package static let shared = CustomBrushTipLibrary()

    package private(set) var tips: [UUID] = CustomBrushTips.saved()

    package func add(_ picture: CGImage) throws -> UUID {
        let id = try CustomBrushTips.add(picture)
        tips.append(id)
        return id
    }

    package func delete(_ id: UUID) {
        CustomBrushTips.delete(id)
        BrushTipImage.forget(id)
        tips.removeAll { $0 == id }
    }
}
