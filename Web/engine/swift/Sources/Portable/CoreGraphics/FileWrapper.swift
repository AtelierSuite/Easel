import Foundation

/// Foundation's FileWrapper, which WebAssembly's Foundation lacks: a tree of
/// files in memory. Packages arrive from the page this way.
open class FileWrapper: @unchecked Sendable {
    public private(set) var regularFileContents: Data?
    public private(set) var fileWrappers: [String: FileWrapper]?
    public var preferredFilename: String?
    public var filename: String?

    public var isDirectory: Bool { fileWrappers != nil }
    public var isRegularFile: Bool { regularFileContents != nil }

    public init(regularFileWithContents contents: Data) {
        regularFileContents = contents
    }

    public init(directoryWithFileWrappers children: [String: FileWrapper]) {
        for (name, child) in children where child.preferredFilename == nil { child.preferredFilename = name }
        fileWrappers = children
    }

    public init(url: URL, options: ReadingOptions = []) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CocoaError(.fileReadNoSuchFile) }
        if isDirectory.boolValue {
            var children: [String: FileWrapper] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                children[name] = try FileWrapper(url: url.appendingPathComponent(name))
            }
            fileWrappers = children
        } else {
            regularFileContents = try Data(contentsOf: url)
        }
        preferredFilename = url.lastPathComponent
        filename = url.lastPathComponent
    }

    @discardableResult
    public func addFileWrapper(_ child: FileWrapper) -> String {
        let name = child.preferredFilename ?? UUID().uuidString
        if fileWrappers == nil { fileWrappers = [:] }
        fileWrappers?[name] = child
        return name
    }

    @discardableResult
    public func addRegularFile(withContents data: Data, preferredFilename name: String) -> String {
        let child = FileWrapper(regularFileWithContents: data)
        child.preferredFilename = name
        return addFileWrapper(child)
    }

    public func removeFileWrapper(_ child: FileWrapper) {
        guard let key = fileWrappers?.first(where: { $0.value === child })?.key else { return }
        fileWrappers?[key] = nil
    }

    public func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL? = nil) throws {
        if let fileWrappers {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, child) in fileWrappers { try child.write(to: url.appendingPathComponent(name), options: options) }
        } else {
            try (regularFileContents ?? Data()).write(to: url)
        }
    }

    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let immediate = ReadingOptions(rawValue: 1)
        public static let withoutMapping = ReadingOptions(rawValue: 2)
    }

    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let atomic = WritingOptions(rawValue: 1)
        public static let withNameUpdating = WritingOptions(rawValue: 2)
    }
}

extension FileManager {
    /// No app groups on the web; callers fall back on Application Support.
    public func containerURL(forSecurityApplicationGroupIdentifier identifier: String) -> URL? { nil }
}
