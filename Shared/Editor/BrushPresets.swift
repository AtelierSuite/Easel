import Foundation
import Observation
import Paintbrush

/// A brush kept by name: everything about it but its colour, which stays
/// whatever is in use.
struct BrushPreset: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var tip: BrushTip
    var size: Double
    var opacity: Double
    var softness: Double
    var usesPressure: Bool
    var usesTilt: Bool
    /// Missing from brushes saved before there were dynamics.
    var dynamics: BrushDynamics?
    var customTip: UUID?

    init(name: String, settings: BrushSettings) {
        self.name = name
        tip = settings.tip
        size = settings.size
        opacity = settings.opacity
        softness = settings.softness
        usesPressure = settings.usesPressure
        usesTilt = settings.usesTilt
        dynamics = settings.dynamics
        customTip = settings.customTip
    }

    /// `settings` taking this brush's shape, keeping their colour.
    func applied(to settings: BrushSettings) -> BrushSettings {
        var result = settings
        result.tip = tip
        result.size = size
        result.opacity = opacity
        result.softness = softness
        result.usesPressure = usesPressure
        result.usesTilt = usesTilt
        result.dynamics = dynamics ?? BrushDynamics()
        result.customTip = customTip
        return result
    }

    /// The brushes that come with the app.
    static let builtIn: [BrushPreset] = [
        BrushPreset(name: String(localized: "Brush.Preset.Ink"), settings: BrushSettings(size: 8)),
        // Inking line work: fine at both ends, thinning on quick strokes.
        BrushPreset(name: String(localized: "Brush.Preset.DipPen"), settings: {
            var settings = BrushSettings(size: 10)
            settings.dynamics.taper = 0.5
            settings.dynamics.speed = 0.6
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Sketch"), settings: {
            var settings = BrushSettings(size: 6, opacity: 0.9)
            settings.tip = .pencil
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.BrushPen"), settings: {
            var settings = BrushSettings(size: 28)
            settings.tip = .calligraphy
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.SoftAirbrush"), settings: {
            var settings = BrushSettings(size: 160, opacity: 0.6, usesPressure: false)
            settings.tip = .airbrush
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Pastel"), settings: {
            var settings = BrushSettings(size: 48)
            settings.tip = .chalk
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Marker"), settings: {
            var settings = BrushSettings(size: 30, opacity: 0.75, softness: 0.1)
            settings.tip = .marker
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Charcoal"), settings: {
            var settings = BrushSettings(size: 26)
            settings.tip = .charcoal
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Crayon"), settings: {
            var settings = BrushSettings(size: 22)
            settings.tip = .crayon
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Stipple"), settings: {
            var settings = BrushSettings(size: 24)
            settings.tip = .stipple
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Pixel"), settings: {
            var settings = BrushSettings(size: 1, usesPressure: false)
            settings.tip = .pixel
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Bristle"), settings: {
            var settings = BrushSettings(size: 40)
            settings.tip = .bristle
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.DryBrush"), settings: {
            var settings = BrushSettings(size: 50)
            settings.tip = .dryBrush
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Flat"), settings: {
            var settings = BrushSettings(size: 44, usesPressure: false)
            settings.tip = .flat
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Spatter"), settings: {
            var settings = BrushSettings(size: 60, usesPressure: false)
            settings.tip = .spatter
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Sponge"), settings: {
            var settings = BrushSettings(size: 70, usesPressure: false)
            settings.tip = .sponge
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Foliage"), settings: {
            var settings = BrushSettings(size: 50, usesPressure: false)
            settings.tip = .foliage
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Stars"), settings: {
            var settings = BrushSettings(size: 36, usesPressure: false)
            settings.tip = .stars
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Confetti"), settings: {
            var settings = BrushSettings(size: 40, usesPressure: false)
            settings.tip = .confetti
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Neon"), settings: {
            var settings = BrushSettings(size: 20, usesPressure: false)
            settings.tip = .neon
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Watercolor"), settings: {
            var settings = BrushSettings(size: 60, opacity: 0.8, softness: 0.3)
            settings.tip = .watercolor
            return settings
        }()),
        BrushPreset(name: String(localized: "Brush.Preset.Oil"), settings: {
            var settings = BrushSettings(size: 40)
            settings.tip = .oil
            return settings
        }()),
    ]
}

/// The brushes someone has saved, kept between launches and shared with the
/// Photos editing extension.
@MainActor
@Observable
final class BrushLibrary {
    static let shared = BrushLibrary(defaults: UserDefaults(suiteName: SharedContainer.appGroup) ?? .standard)

    private(set) var saved: [BrushPreset]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "SavedBrushes"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([BrushPreset].self, from: $0) } ?? []
    }

    /// Keeps `settings` as a brush called `name`.
    func save(_ settings: BrushSettings, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saved.append(BrushPreset(name: trimmed, settings: settings))
        persist()
    }

    func delete(_ preset: BrushPreset) {
        saved.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }
}
