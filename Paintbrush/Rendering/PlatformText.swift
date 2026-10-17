import CoreGraphics
#if canImport(UIKit)
import UIKit

package typealias PlatformFont = UIFont
package typealias PlatformFontDescriptor = UIFontDescriptor
package typealias PlatformColor = UIColor
#else
import AppKit

package typealias PlatformFont = NSFont
package typealias PlatformFontDescriptor = NSFontDescriptor
package typealias PlatformColor = NSColor
#endif

/// What text rendering needs from fonts, the same on iOS and macOS.
extension PlatformFontDescriptor {
    /// The descriptor made bold or italic as well, where its family has
    /// such a face.
    package func adding(bold: Bool = false, italic: Bool = false) -> PlatformFontDescriptor {
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

    package var isBold: Bool {
        #if canImport(UIKit)
        symbolicTraits.contains(.traitBold)
        #else
        symbolicTraits.contains(.bold)
        #endif
    }

    package var isItalic: Bool {
        #if canImport(UIKit)
        symbolicTraits.contains(.traitItalic)
        #else
        symbolicTraits.contains(.italic)
        #endif
    }
}

extension PlatformFont {
    /// Whether a family of this name is installed.
    package static func isInstalled(family: String) -> Bool {
        #if canImport(UIKit)
        !UIFont.fontNames(forFamilyName: family).isEmpty
        #else
        !(NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).isEmpty
        #endif
    }

    /// The font a descriptor describes, or the system font where none matches.
    package static func described(by descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        UIFont(descriptor: descriptor, size: size)
        #else
        NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        #endif
    }

    /// The family the font belongs to; the system font's starts with a dot.
    package var family: String {
        #if canImport(UIKit)
        familyName
        #else
        familyName ?? ""
        #endif
    }
}

extension RGBAColor {
    package var platformColor: PlatformColor {
        #if canImport(UIKit)
        UIColor(cgColor: cgColor)
        #else
        NSColor(cgColor: cgColor) ?? .black
        #endif
    }
}

/// Runs `draw` with `context` as the one string and image drawing go into,
/// set up with y running down.
package func drawing(into context: CGContext, _ draw: () -> Void) {
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
