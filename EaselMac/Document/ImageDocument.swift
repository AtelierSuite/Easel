import AppKit
import Paintbrush
import UniformTypeIdentifiers

/// A picture open in a window: a layered `.easel` package, a plain picture
/// edited where it lies (and so flattened when saved), or a Photoshop or
/// Pixelmator Pro document written back into itself.
///
/// Reading and writing are the iOS app's, through `EaselDocument`; this adds
/// what a Mac document does besides: autosaving, versions, and the copy a
/// Photoshop or Pixelmator Pro file that would lose something is saved as
/// before it is edited.
final class ImageDocument: NSDocument {
    /// The picture as the editor last handed it over.
    var composition: Composition = .blank() {
        didSet { if !isPublishing { compositionReplaced?(composition) } }
    }

    /// Told when the picture changes other than from the editor, such as
    /// when the document reverts to a saved version.
    var compositionReplaced: ((Composition) -> Void)?

    private var isPublishing = false
    /// The file as last read or written: Pixelmator Pro documents are saved
    /// by patching it, and a file that has to be copied first is written
    /// back exactly as it was.
    private var fileContents: FileWrapper?
    /// Set while a Save panel offers only an Easel image, for the copy.
    private var isSavingCopy = false

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    /// Takes in a change made in the editor.
    func publish(_ composition: Composition) {
        isPublishing = true
        self.composition = composition
        isPublishing = false
        updateChangeCount(.changeDone)
    }

    // MARK: - Reading and writing

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let contentType = UTType(typeName) else { throw CocoaError(.fileReadUnknown) }
        composition = try EaselDocument.composition(from: fileWrapper, contentType: contentType)
        fileContents = fileWrapper
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard let contentType = UTType(typeName) else { throw CocoaError(.fileWriteUnknown) }
        let written = try EaselDocument(composition: composition).written(as: contentType, existing: fileContents)
        fileContents = written
        return written
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        isSavingCopy ? [UTType.easelImage.identifier] : super.writableTypes(for: saveOperation)
    }

    /// A new picture is saved as an Easel image, which keeps its layers.
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        UTType(typeName)?.preferredFilenameExtension ?? super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    // MARK: - Copying before editing

    /// Whether the file is a Photoshop or Pixelmator Pro document that would
    /// lose something written back, not yet saved as an Easel copy.
    var requiresCopyBeforeEditing: Bool {
        guard let fileURL else { return false }
        return DocumentConversion.requiresCopy(fileURL, composition: composition)
    }

    /// Asks where to save the Easel copy, and from then on edits that copy,
    /// leaving the original file as it was.
    func saveCopy(completion: @escaping (Bool) -> Void) {
        isSavingCopy = true
        let handler = SaveCompletion { [weak self] saved in
            self?.isSavingCopy = false
            completion(saved)
        }
        runModalSavePanel(
            for: .saveAsOperation, delegate: handler,
            didSave: #selector(SaveCompletion.document(_:didSave:contextInfo:)), contextInfo: nil
        )
    }

    /// Turns a plain picture, which is flattened when saved, into an Easel
    /// image beside it that keeps its layers; the window follows it.
    func convertToEasel() async throws {
        guard let fileURL else { return }
        let destination = try await DocumentConversion.convert(fileAt: fileURL, composition: composition)
        self.fileURL = destination
        fileType = UTType.easelImage.identifier
        fileContents = try? FileWrapper(url: destination)
    }
}

/// Hands the result of a Save panel run for a document to a closure, as the
/// Objective-C style callback asks for an object and selector.
private final class SaveCompletion: NSObject {
    private let completion: (Bool) -> Void
    private var keepAlive: SaveCompletion?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init()
        keepAlive = self
    }

    @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(didSave)
        keepAlive = nil
    }
}
