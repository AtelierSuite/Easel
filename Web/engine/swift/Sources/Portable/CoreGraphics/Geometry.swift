@_exported import Foundation

// Core Foundation's types, which Paintbrush only ever bridges to and from
// Foundation's, are Foundation's own here.
public typealias CFData = Data
public typealias CFMutableData = NSMutableData
public typealias CFString = String
public typealias CFURL = URL
public typealias CFDictionary = [String: Any]
public typealias CFArray = [Any]
public typealias CFTypeRef = AnyObject
public typealias CFIndex = Int

public struct CFRange: Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public func CFRangeMake(_ location: Int, _ length: Int) -> CFRange { CFRange(location: location, length: length) }

public struct CGVector: Hashable, Codable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
    public init(dx: Double, dy: Double) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }
    public init(dx: Int, dy: Int) {
        self.dx = CGFloat(dx)
        self.dy = CGFloat(dy)
    }
    public static let zero = CGVector(dx: 0, dy: 0)
}

public struct CGAffineTransform: Hashable, Codable, Sendable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) {
        self.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var isIdentity: Bool { self == .identity }

    public init(translationX x: CGFloat, y: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public init(scaleX x: CGFloat, y: CGFloat) {
        self.init(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    public init(rotationAngle angle: CGFloat) {
        let s = sin(angle), c = cos(angle)
        self.init(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }

    /// `self` applied first, then `other`.
    public func concatenating(_ other: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * other.a + b * other.c, b: a * other.b + b * other.d,
            c: c * other.a + d * other.c, d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx, ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: x, y: y).concatenating(self)
    }

    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).concatenating(self)
    }

    public func rotated(by angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle).concatenating(self)
    }

    public func inverted() -> CGAffineTransform {
        let determinant = a * d - b * c
        guard determinant != 0, determinant.isFinite else { return self }
        let ia = d / determinant, ib = -b / determinant, ic = -c / determinant, id = a / determinant
        return CGAffineTransform(a: ia, b: ib, c: ic, d: id, tx: -(tx * ia + ty * ic), ty: -(tx * ib + ty * id))
    }

    public struct Components: Sendable {
        public var scale: CGSize
        public var horizontalShear: CGFloat
        public var rotation: CGFloat
        public var translation: CGVector
        public init(scale: CGSize = CGSize(width: 1, height: 1), horizontalShear: CGFloat = 0, rotation: CGFloat = 0, translation: CGVector = .zero) {
            self.scale = scale
            self.horizontalShear = horizontalShear
            self.rotation = rotation
            self.translation = translation
        }
    }

    public var decomposed: Components {
        let sx = hypot(a, b)
        let rotation = atan2(b, a)
        let determinant = a * d - b * c
        let sy = sx == 0 ? hypot(c, d) : determinant / sx
        let shear = sx == 0 ? 0 : (a * c + b * d) / (sx * sx)
        return Components(scale: CGSize(width: sx, height: sy), horizontalShear: shear, rotation: rotation, translation: CGVector(dx: tx, dy: ty))
    }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

extension CGSize {
    public func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

extension CGRect {
    public func applying(_ t: CGAffineTransform) -> CGRect {
        if isNull { return self }
        if isInfinite { return self }
        let r = standardized
        let corners = [
            CGPoint(x: r.minX, y: r.minY).applying(t), CGPoint(x: r.maxX, y: r.minY).applying(t),
            CGPoint(x: r.minX, y: r.maxY).applying(t), CGPoint(x: r.maxX, y: r.maxY).applying(t),
        ]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return CGRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }
}

public enum CGRectEdge: Sendable {
    case minXEdge, minYEdge, maxXEdge, maxYEdge
}

extension CGRect {
    public func divided(atDistance distance: CGFloat, from edge: CGRectEdge) -> (slice: CGRect, remainder: CGRect) {
        let r = standardized
        switch edge {
        case .minXEdge:
            let d = min(max(distance, 0), r.width)
            return (CGRect(x: r.minX, y: r.minY, width: d, height: r.height), CGRect(x: r.minX + d, y: r.minY, width: r.width - d, height: r.height))
        case .maxXEdge:
            let d = min(max(distance, 0), r.width)
            return (CGRect(x: r.maxX - d, y: r.minY, width: d, height: r.height), CGRect(x: r.minX, y: r.minY, width: r.width - d, height: r.height))
        case .minYEdge:
            let d = min(max(distance, 0), r.height)
            return (CGRect(x: r.minX, y: r.minY, width: r.width, height: d), CGRect(x: r.minX, y: r.minY + d, width: r.width, height: r.height - d))
        case .maxYEdge:
            let d = min(max(distance, 0), r.height)
            return (CGRect(x: r.minX, y: r.maxY - d, width: r.width, height: d), CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - d))
        }
    }
}

public typealias CGGlyph = UInt16
