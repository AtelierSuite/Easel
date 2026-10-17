import Foundation
import Paintbrush

/// What Easel keeps in a photo's adjustment data so its layers come back.
///
/// Photos refuses adjustment data past two megabytes — a single full-size
/// layer is more than that — so small edits travel inline and larger ones
/// are kept in the container the app and its Photos extension share, with
/// only their name in the adjustment data. Where that copy is missing, such
/// as on another device, the edit is opened as the flattened photo instead.
enum PhotoEditPayload {
    /// Comfortably under the 2 MiB Photos accepts; setting more raises an
    /// exception rather than an error.
    static let inlineLimit = 1_500_000

    private enum Stored: Codable {
        case inline(Data)
        case file(String)
    }

    /// The adjustment data for an archived composition, saving it to the
    /// shared container when it is too big to go inline.
    static func encode(_ archive: Data) throws -> Data {
        if archive.count <= inlineLimit {
            return try PropertyListEncoder().encode(Stored.inline(archive))
        }
        guard let folder else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).easeledit"
        try archive.write(to: folder.appending(path: name), options: .atomic)
        return try PropertyListEncoder().encode(Stored.file(name))
    }

    /// The archived composition, if it is here to be read.
    static func decode(_ data: Data) -> Data? {
        switch try? PropertyListDecoder().decode(Stored.self, from: data) {
        case .inline(let archive): return archive
        case .file(let name): return folder.flatMap { try? Data(contentsOf: $0.appending(path: name)) }
        case nil: return nil
        }
    }

    /// Deletes the copy kept in the shared container for this adjustment
    /// data, once nothing refers to it: the edit was replaced, reverted or
    /// never saved.
    static func discard(_ data: Data?) {
        guard let data, case .file(let name) = try? PropertyListDecoder().decode(Stored.self, from: data),
              let url = folder?.appending(path: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether `decode` would find the composition, without reading it.
    static func isAvailable(_ data: Data) -> Bool {
        switch try? PropertyListDecoder().decode(Stored.self, from: data) {
        case .inline: return true
        case .file(let name):
            return folder.map { FileManager.default.fileExists(atPath: $0.appending(path: name).path) } ?? false
        case nil: return false
        }
    }

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroup)?
            .appending(path: "Photo Edits", directoryHint: .isDirectory)
    }
}
