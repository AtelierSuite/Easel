@_exported import CoreGraphics

// The few SwiftUI values Paintbrush's model uses: colours and localised labels.

public struct LocalizedStringKey: ExpressibleByStringInterpolation, Hashable, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
    public init(stringLiteral value: String) { key = value }
}

public struct EnvironmentValues: Sendable {
    public init() {}
}

public struct Color: Hashable, Sendable {
    public enum RGBColorSpace: Sendable { case sRGB, sRGBLinear, displayP3 }

    public struct Resolved: Hashable, Sendable {
        public var red: Float
        public var green: Float
        public var blue: Float
        public var opacity: Float
    }

    let resolved: Resolved

    public init(_ space: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        resolved = Resolved(red: Float(red), green: Float(green), blue: Float(blue), opacity: Float(opacity))
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(.sRGB, red: white, green: white, blue: white, opacity: opacity)
    }

    public init(cgColor: CGColor) {
        let c = cgColor.rgba
        self.init(.sRGB, red: Double(c.0), green: Double(c.1), blue: Double(c.2), opacity: Double(c.3))
    }

    public func resolve(in environment: EnvironmentValues) -> Resolved { resolved }

    public var cgColor: CGColor? {
        CGColor(red: CGFloat(resolved.red), green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }

    public func opacity(_ value: Double) -> Color {
        Color(.sRGB, red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), opacity: Double(resolved.opacity) * value)
    }

    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let clear = Color(white: 0, opacity: 0)
    public static let red = Color(red: 1, green: 0.231, blue: 0.188)
    public static let green = Color(red: 0.204, green: 0.78, blue: 0.349)
    public static let blue = Color(red: 0, green: 0.478, blue: 1)
    public static let orange = Color(red: 1, green: 0.584, blue: 0)
    public static let yellow = Color(red: 1, green: 0.8, blue: 0)
    public static let gray = Color(red: 0.557, green: 0.557, blue: 0.576)
    public static let accentColor = Color(red: 0, green: 0.478, blue: 1)
}

public enum BlendMode: Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight, difference,
         exclusion, hue, saturation, color, luminosity, sourceAtop, destinationOver, destinationOut, plusDarker, plusLighter
}

extension Array {
    /// Moves the elements at `offsets` to before `destination`, as SwiftUI's lists do.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().filter { indices.contains($0) }.map { self[$0] }
        let before = offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) where indices.contains(offset) { remove(at: offset) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(destination - before, 0), count))
    }
}
