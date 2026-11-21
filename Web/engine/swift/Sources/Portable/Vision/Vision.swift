@_exported import CoreGraphics
import CoreVideo

// Subject lifting needs Apple's on-device model; on the web the request
// fails, which Paintbrush reports as unavailable.

public struct VisionError: Error {}

public class VNRequest {
    public init() {}
}

public final class VNInstanceMaskObservation {
    public var allInstances: IndexSet { [] }
    public var instanceMask: CVPixelBuffer { CVPixelBuffer(width: 1, height: 1, bytesPerRow: 1, format: kCVPixelFormatType_OneComponent8) }
    public func generateScaledMaskForImage(forInstances instances: IndexSet, from handler: VNImageRequestHandler) throws -> CVPixelBuffer {
        throw VisionError()
    }
}

public final class VNGenerateForegroundInstanceMaskRequest: VNRequest {
    public var results: [VNInstanceMaskObservation]? { nil }
}

public final class VNImageRequestHandler {
    public init(cgImage: CGImage, options: [String: Any] = [:]) {}
    public func perform(_ requests: [VNRequest]) throws { throw VisionError() }
}
