import Foundation

/// Turns a plain picture file, which can only be saved flattened, into an
/// Easel image that keeps its layers — in place, the way Rename moves a file,
/// so the open document follows it and from then on saves as a package.
/// Photoshop and Pixelmator Pro documents are never edited in place: before
/// anything changes, they are saved as an Easel copy wherever the person
/// picks, and the open document follows that copy instead.
enum DocumentConversion {
    static func canConvert(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() != "easel" && !requiresCopy(fileURL)
    }

    /// Whether the file has to be saved as an Easel copy before it is edited:
    /// its layers, effects and masks would not all survive being written back.
    static func requiresCopy(_ fileURL: URL) -> Bool {
        ["psd", "psb", "pxd"].contains(fileURL.pathExtension.lowercased())
    }

    /// Moves the file to an `.easel` name beside it and writes the
    /// composition there, returning where it now lives.
    ///
    /// Off the main actor: the open document has to give the file up before
    /// the coordinator lets this touch it, and it does that on the main thread.
    @concurrent
    static func convert(fileAt url: URL, composition: Composition) async throws -> URL {
        let wrapper = try CompositionArchive.fileWrapper(for: composition)
        let destination = availableURL(
            for: url.deletingPathExtension().lastPathComponent, in: url.deletingLastPathComponent()
        )

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var failure: Error?
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { source, target in
            do {
                try FileManager.default.moveItem(at: source, to: target)
                coordinator.item(at: source, didMoveTo: target)
                // After the move, so the document reading it back already
                // knows it by its new type. A package is a folder, so the
                // picture moved there is replaced outright.
                try FileManager.default.removeItem(at: target)
                try wrapper.write(to: target, options: .atomic, originalContentsURL: nil)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
        return destination
    }

    /// Points the open document at a copy already saved elsewhere, as though
    /// the original had moved there, leaving the original untouched.
    ///
    /// Off the main actor, for the same reason as `convert`.
    @concurrent
    static func adopt(copyAt destination: URL, of url: URL) async throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: destination, options: [],
            error: &coordinationError
        ) { source, target in
            coordinator.item(at: source, didMoveTo: target)
        }
        if let coordinationError { throw coordinationError }
    }

    /// `name.easel`, or `name 2.easel` and upwards when that is taken.
    private static func availableURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension("easel")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension("easel")
            number += 1
        }
        return candidate
    }
}
