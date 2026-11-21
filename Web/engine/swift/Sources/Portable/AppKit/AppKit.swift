@_exported import CoreGraphics
import EaselHost

// The parts of AppKit's text system Paintbrush sets type with on the Mac,
// over TextSystem, which asks the page.

public final class NSFont: @unchecked Sendable, Hashable {
    public struct Weight: Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let ultraLight = Weight(rawValue: -0.8)
        public static let thin = Weight(rawValue: -0.6)
        public static let light = Weight(rawValue: -0.4)
        public static let regular = Weight(rawValue: 0)
        public static let medium = Weight(rawValue: 0.23)
        public static let semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4)
        public static let heavy = Weight(rawValue: 0.56)
        public static let black = Weight(rawValue: 0.62)
    }

    public let fontDescriptor: NSFontDescriptor
    public let pointSize: CGFloat

    init(descriptor: NSFontDescriptor, pointSize: CGFloat) {
        fontDescriptor = descriptor
        self.pointSize = pointSize
    }

    public convenience init?(descriptor: NSFontDescriptor, size: CGFloat) {
        self.init(descriptor: descriptor, pointSize: size == 0 ? 12 : size)
    }

    public convenience init?(name: String, size: CGFloat) {
        self.init(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), pointSize: size)
    }

    public static func systemFont(ofSize size: CGFloat, weight: Weight = .regular) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if weight.rawValue >= Weight.semibold.rawValue { traits.insert(.bold) }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: [:], traits: traits, design: .default), pointSize: size)
    }

    public static func boldSystemFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size, weight: .bold) }

    public var familyName: String? { fontDescriptor.family ?? ".AppleSystemUIFont" }
    public var fontName: String { familyName ?? "" }
    public var displayName: String? { familyName }
    var isSystem: Bool { fontDescriptor.family == nil }
    var family: String? { fontDescriptor.family }
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
    var design: String { fontDescriptor.design.rawValue }
    public var ascender: CGFloat { pointSize * 0.8 }
    public var descender: CGFloat { -pointSize * 0.2 }
    public var leading: CGFloat { 0 }
    public var capHeight: CGFloat { pointSize * 0.7 }
    public var xHeight: CGFloat { pointSize * 0.5 }

    public func withSize(_ size: CGFloat) -> NSFont { NSFont(descriptor: fontDescriptor, pointSize: size) }

    public static func == (lhs: NSFont, rhs: NSFont) -> Bool { lhs.fontDescriptor == rhs.fontDescriptor && lhs.pointSize == rhs.pointSize }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(fontDescriptor)
        hasher.combine(pointSize)
    }
}

public final class NSFontDescriptor: @unchecked Sendable, Hashable {
    public struct AttributeName: Hashable, Sendable {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let family = AttributeName("NSFontFamilyAttribute")
        public static let name = AttributeName("NSFontNameAttribute")
        public static let face = AttributeName("NSFontFaceAttribute")
        public static let size = AttributeName("NSFontSizeAttribute")
        public static let traits = AttributeName("NSCTFontTraitsAttribute")
    }

    public struct SymbolicTraits: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let italic = SymbolicTraits(rawValue: 1 << 0)
        public static let bold = SymbolicTraits(rawValue: 1 << 1)
        public static let monoSpace = SymbolicTraits(rawValue: 1 << 10)
    }

    public struct SystemDesign: Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let `default` = SystemDesign(rawValue: "default")
        public static let serif = SystemDesign(rawValue: "serif")
        public static let rounded = SystemDesign(rawValue: "rounded")
        public static let monospaced = SystemDesign(rawValue: "monospaced")
    }

    let family: String?
    public let symbolicTraits: SymbolicTraits
    let design: SystemDesign

    public init(fontAttributes attributes: [AttributeName: Any] = [:]) {
        family = attributes[.family] as? String ?? attributes[.name] as? String
        symbolicTraits = []
        design = .default
    }

    init(fontAttributes attributes: [AttributeName: Any], traits: SymbolicTraits, design: SystemDesign) {
        family = attributes[.family] as? String ?? attributes[.name] as? String
        symbolicTraits = traits
        self.design = design
    }

    init(family: String?, traits: SymbolicTraits, design: SystemDesign) {
        self.family = family
        symbolicTraits = traits
        self.design = design
    }

    public var fontAttributes: [AttributeName: Any] { family.map { [.family: $0] } ?? [:] }

    public func withSymbolicTraits(_ traits: SymbolicTraits) -> NSFontDescriptor {
        NSFontDescriptor(family: family, traits: traits, design: design)
    }

    public func withDesign(_ design: SystemDesign) -> NSFontDescriptor? {
        NSFontDescriptor(family: family, traits: symbolicTraits, design: design)
    }

    public func withFamily(_ family: String) -> NSFontDescriptor {
        NSFontDescriptor(family: family, traits: symbolicTraits, design: design)
    }

    public static func == (lhs: NSFontDescriptor, rhs: NSFontDescriptor) -> Bool {
        lhs.family == rhs.family && lhs.symbolicTraits == rhs.symbolicTraits && lhs.design == rhs.design
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(symbolicTraits)
        hasher.combine(design)
    }
}

public final class NSFontManager: @unchecked Sendable {
    public static let shared = NSFontManager()

    /// The members of a family the browser has, as AppKit lists them, or nil.
    public func availableMembers(ofFontFamily family: String) -> [[Any]]? {
        FontAvailability.isInstalled(family) ? [[family, "Regular", 5, 0]] : nil
    }

    public var availableFontFamilies: [String] { [] }
}

enum FontAvailability {
    nonisolated(unsafe) static var known: [String: Bool] = [:]

    static func isInstalled(_ family: String) -> Bool {
        if let answer = known[family] { return answer }
        struct Request: Encodable { var op = "font"; var family: String }
        var answer = false
        if let json = try? JSONEncoder().encode(Request(family: family)) {
            let length = json.withUnsafeBytes { easel_host_text($0.baseAddress!.assumingMemoryBound(to: UInt8.self), Int32($0.count)) }
            if length > 0 {
                var result = [UInt8](repeating: 0, count: Int(length))
                result.withUnsafeMutableBufferPointer { easel_host_result($0.baseAddress!) }
                answer = result.first == UInt8(ascii: "1")
            }
        }
        known[family] = answer
        return answer
    }
}

public final class NSColor: @unchecked Sendable, Hashable {
    let components: [Double]

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        components = [Double(red), Double(green), Double(blue), Double(alpha)]
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public convenience init(white: CGFloat, alpha: CGFloat) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public convenience init?(cgColor: CGColor) {
        let c = cgColor.rgba
        self.init(red: c.0, green: c.1, blue: c.2, alpha: c.3)
    }

    public var cgColor: CGColor {
        CGColor(red: CGFloat(components[0]), green: CGFloat(components[1]), blue: CGFloat(components[2]), alpha: CGFloat(components[3]))
    }

    public var redComponent: CGFloat { CGFloat(components[0]) }
    public var greenComponent: CGFloat { CGFloat(components[1]) }
    public var blueComponent: CGFloat { CGFloat(components[2]) }
    public var alphaComponent: CGFloat { CGFloat(components[3]) }

    public static let black = NSColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = NSColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let clear = NSColor(red: 0, green: 0, blue: 0, alpha: 0)

    public static func == (lhs: NSColor, rhs: NSColor) -> Bool { lhs.components == rhs.components }
    public func hash(into hasher: inout Hasher) { hasher.combine(components) }
}

public final class NSGraphicsContext: @unchecked Sendable {
    public let cgContext: CGContext
    public let isFlipped: Bool
    nonisolated(unsafe) private static var stack: [NSGraphicsContext?] = []
    nonisolated(unsafe) public static var current: NSGraphicsContext?

    public init(cgContext: CGContext, flipped: Bool) {
        self.cgContext = cgContext
        isFlipped = flipped
    }

    public static func saveGraphicsState() { stack.append(current) }

    public static func restoreGraphicsState() {
        if let last = stack.popLast() { current = last }
    }
}

public enum NSTextAlignment: Int, Sendable {
    case left = 0, right = 1, center = 2, justified = 3, natural = 4
}

public enum NSLineBreakMode: Int, Sendable {
    case byWordWrapping = 0, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle
}

public class NSParagraphStyle: NSObject, @unchecked Sendable {
    public internal(set) var alignment: NSTextAlignment = .natural
    public internal(set) var lineHeightMultiple: CGFloat = 0
    public internal(set) var lineSpacing: CGFloat = 0
    public internal(set) var paragraphSpacing: CGFloat = 0
    public internal(set) var lineBreakMode: NSLineBreakMode = .byWordWrapping
    public static let `default` = NSParagraphStyle()
}

public final class NSMutableParagraphStyle: NSParagraphStyle, @unchecked Sendable {
    override public var alignment: NSTextAlignment {
        get { super.alignment }
        set { super.alignment = newValue }
    }
    override public var lineHeightMultiple: CGFloat {
        get { super.lineHeightMultiple }
        set { super.lineHeightMultiple = newValue }
    }
    override public var lineSpacing: CGFloat {
        get { super.lineSpacing }
        set { super.lineSpacing = newValue }
    }
    override public var paragraphSpacing: CGFloat {
        get { super.paragraphSpacing }
        set { super.paragraphSpacing = newValue }
    }
    override public var lineBreakMode: NSLineBreakMode {
        get { super.lineBreakMode }
        set { super.lineBreakMode = newValue }
    }
}

public struct NSUnderlineStyle: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let single = NSUnderlineStyle(rawValue: 1)
    public static let thick = NSUnderlineStyle(rawValue: 2)
    public static let double = NSUnderlineStyle(rawValue: 9)
}

extension NSAttributedString.Key {
    public static let font = NSAttributedString.Key("NSFont")
    public static let foregroundColor = NSAttributedString.Key("NSColor")
    public static let backgroundColor = NSAttributedString.Key("NSBackgroundColor")
    public static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    public static let kern = NSAttributedString.Key("NSKern")
    public static let tracking = NSAttributedString.Key("NSTracking")
    public static let underlineStyle = NSAttributedString.Key("NSUnderline")
    public static let strikethroughStyle = NSAttributedString.Key("NSStrikethrough")
    public static let baselineOffset = NSAttributedString.Key("NSBaselineOffset")
    public static let strokeColor = NSAttributedString.Key("NSStrokeColor")
    public static let strokeWidth = NSAttributedString.Key("NSStrokeWidth")
    public static let ligature = NSAttributedString.Key("NSLigature")
}

public struct NSStringDrawingOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let usesLineFragmentOrigin = NSStringDrawingOptions(rawValue: 1 << 0)
    public static let usesFontLeading = NSStringDrawingOptions(rawValue: 1 << 1)
    public static let usesDeviceMetrics = NSStringDrawingOptions(rawValue: 1 << 3)
    public static let truncatesLastVisibleLine = NSStringDrawingOptions(rawValue: 1 << 5)
}

public final class NSStringDrawingContext {
    public init() {}
}

extension NSAttributedString {
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = [], context: NSStringDrawingContext? = nil) -> CGRect {
        let width = size.width.isFinite && size.width < 1e7 ? Double(size.width) : nil
        let layout = TextSystem.layout(self, width: width)
        return CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
    }

    public func size() -> CGSize { boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).size }

    /// Draws into the current graphics context, which is flipped (y down).
    public func draw(with rect: CGRect, options: NSStringDrawingOptions = [], context: NSStringDrawingContext? = nil) {
        guard let cg = NSGraphicsContext.current?.cgContext, rect.width > 0, rect.height > 0 else { return }
        let ctm = cg.ctm
        let scale = max(sqrt(abs(Double(ctm.a * ctm.d - ctm.b * ctm.c))), 0.01)
        guard let image = TextSystem.render(self, width: Double(rect.width), height: Double(rect.height), scale: scale) else { return }
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    public func draw(in rect: CGRect) { draw(with: rect, options: [.usesLineFragmentOrigin]) }

    public func draw(at point: CGPoint) {
        let size = size()
        draw(with: CGRect(origin: point, size: size), options: [.usesLineFragmentOrigin])
    }
}
