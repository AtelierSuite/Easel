import Foundation

/// Something in a Photoshop or Pixelmator Pro file that saving it back
/// from Easel would lose.
enum WriteBackLoss: String, Sendable, CaseIterable {
    /// 16 or 32 bits a channel, which Easel keeps as 8.
    case depth
    /// Greys, CMYK or bitmap, which Easel keeps as RGB.
    case colorMode
    /// Alpha or spot channels beside the picture's own.
    case extraChannels
    /// Layers whose pixels could not be read, in either kind of file.
    case layers
    /// Adjustments Easel splits into several, written afresh.
    case adjustments
    /// A user mask and a vector mask, kept only as one.
    case masks
    /// What layer comps say beyond each layer's visibility, position and
    /// blend: their styles, groups and masks.
    case comps
    /// Layers' timeline and other metadata.
    case metadata

    /// What is lost, as the person is told when asked to save a copy.
    var label: String {
        switch self {
        case .depth: String(localized: "WriteBackLoss.Depth")
        case .colorMode: String(localized: "WriteBackLoss.ColorMode")
        case .extraChannels: String(localized: "WriteBackLoss.ExtraChannels")
        case .layers: String(localized: "WriteBackLoss.Layers")
        case .adjustments: String(localized: "WriteBackLoss.Adjustments")
        case .masks: String(localized: "WriteBackLoss.Masks")
        case .comps: String(localized: "WriteBackLoss.Comps")
        case .metadata: String(localized: "WriteBackLoss.Metadata")
        }
    }
}
