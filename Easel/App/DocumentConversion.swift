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
                try replace(source, at: target, with: wrapper, coordinator: coordinator)
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
        return destination
    }

    /// Moves the picture at `source` to `target` and puts the package in its
    /// place. The package is written aside first, and the picture is only
    /// removed once the package is where it was; until then a failure puts
    /// the picture back as it was.
    private static func replace(
        _ source: URL, at target: URL, with wrapper: FileWrapper, coordinator: NSFileCoordinator
    ) throws {
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? manager.removeItem(at: staging) }
        let package = staging.appending(path: target.lastPathComponent)
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)

        try manager.moveItem(at: source, to: target)
        coordinator.item(at: source, didMoveTo: target)
        // After the move, so the document reading it back already knows it
        // by its new type. A package is a folder, so the picture moved there
        // is set aside and the package moved in.
        let picture = staging.appending(path: "Original-\(source.lastPathComponent)")
        do {
            try manager.moveItem(at: target, to: picture)
            do {
                try manager.moveItem(at: package, to: target)
            } catch {
                try? manager.moveItem(at: picture, to: target)
                throw error
            }
        } catch {
            if (try? manager.moveItem(at: target, to: source)) != nil {
                coordinator.item(at: target, didMoveTo: source)
            }
            throw error
        }
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
