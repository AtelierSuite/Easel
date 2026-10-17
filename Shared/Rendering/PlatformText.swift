import CoreGraphics
#if canImport(UIKit)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
typealias PlatformColor = UIColor
#else
import AppKit

typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
typealias PlatformColor = NSColor
#endif

/// What text rendering needs from fonts, the same on iOS and macOS.
extension PlatformFontDescriptor {
    /// The descriptor made bold or italic as well, where its family has
    /// such a face.
    func adding(bold: Bool = false, italic: Bool = false) -> PlatformFontDescriptor {
        guard bold || italic else { return self }
        var traits = symbolicTraits
        #if canImport(UIKit)
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return withSymbolicTraits(traits) ?? self
        #else
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return withSymbolicTraits(traits)
        #endif
    }

    var isBold: Bool {
        #if canImport(UIKit)
        symbolicTraits.contains(.traitBold)
        #else
        symbolicTraits.contains(.bold)
        #endif
    }

    var isItalic: Bool {
        #if canImport(UIKit)
        symbolicTraits.contains(.traitItalic)
        #else
        symbolicTraits.contains(.italic)
        #endif
    }
}

extension PlatformFont {
    /// Whether a family of this name is installed.
    static func isInstalled(family: String) -> Bool {
        #if canImport(UIKit)
        !UIFont.fontNames(forFamilyName: family).isEmpty
        #else
        !(NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).isEmpty
        #endif
    }

    /// The font a descriptor describes, or the system font where none matches.
    static func described(by descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        UIFont(descriptor: descriptor, size: size)
        #else
        NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        #endif
    }

    /// The family the font belongs to; the system font's starts with a dot.
    var family: String {
        #if canImport(UIKit)
        familyName
        #else
        familyName ?? ""
        #endif
    }
}

extension RGBAColor {
    var platformColor: PlatformColor {
        #if canImport(UIKit)
        UIColor(cgColor: cgColor)
        #else
        NSColor(cgColor: cgColor) ?? .black
        #endif
    }
}

/// Runs `draw` with `context` as the one string and image drawing go into,
/// set up with y running down.
func drawing(into context: CGContext, _ draw: () -> Void) {
    #if canImport(UIKit)
    UIGraphicsPushContext(context)
    draw()
    UIGraphicsPopContext()
    #else
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    #endif
}
