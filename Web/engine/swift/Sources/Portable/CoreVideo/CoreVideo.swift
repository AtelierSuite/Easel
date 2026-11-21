@_exported import CoreGraphics

public final class CVBuffer: @unchecked Sendable {
    let width: Int, height: Int, bytesPerRow: Int, format: OSType
    let data: UnsafeMutableRawPointer
    public init(width: Int, height: Int, bytesPerRow: Int, format: OSType) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.format = format
        data = .allocate(byteCount: max(bytesPerRow * height, 1), alignment: 16)
    }
    deinit { data.deallocate() }
}

public typealias CVPixelBuffer = CVBuffer
public typealias OSType = UInt32
public typealias CVReturn = Int32

public struct CVPixelBufferLockFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let readOnly = CVPixelBufferLockFlags(rawValue: 1)
}

public let kCVPixelFormatType_OneComponent8: OSType = 0x4C30_3038
public let kCVPixelFormatType_OneComponent32Float: OSType = 0x3266_3332

@discardableResult public func CVPixelBufferLockBaseAddress(_ buffer: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) -> CVReturn { 0 }
@discardableResult public func CVPixelBufferUnlockBaseAddress(_ buffer: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) -> CVReturn { 0 }
public func CVPixelBufferGetWidth(_ buffer: CVPixelBuffer) -> Int { buffer.width }
public func CVPixelBufferGetHeight(_ buffer: CVPixelBuffer) -> Int { buffer.height }
public func CVPixelBufferGetBytesPerRow(_ buffer: CVPixelBuffer) -> Int { buffer.bytesPerRow }
public func CVPixelBufferGetBaseAddress(_ buffer: CVPixelBuffer) -> UnsafeMutableRawPointer? { buffer.data }
public func CVPixelBufferGetPixelFormatType(_ buffer: CVPixelBuffer) -> OSType { buffer.format }
