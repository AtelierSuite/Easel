import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import Easel
@testable import Paintbrush

/// Paints the documents the App Store screenshots open, with the app's own
/// brushes, layers, filters, text and vector paths.
///
/// Driven by `Assets/App Store/capture.sh`, which says where to write
/// through `SAMPLES_DIR`. Each language gets a folder of its own there.
/// Without it the test skips, so it stays out of the way of an ordinary run.
final class AppStoreSamples: XCTestCase {
    private static let size = CGSize(width: 1536, height: 2048)

    func testWriteSamples() throws {
        guard let path = ProcessInfo.processInfo.environment["SAMPLES_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        for language in ["en", "ja"] {
            let words = Words(isJapanese: language == "ja")
            let directory = URL(fileURLWithPath: path).appendingPathComponent(language)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(Self.lakeside(words), named: words.lakesideTitle, to: directory)
            try write(Self.poppies(words), named: words.poppiesTitle, to: directory)
            try write(Self.poster(words), named: words.posterTitle, to: directory)
            try write(Self.passport(words), named: words.passportTitle, to: directory)
            try write(Self.plush(words), named: words.plushTitle, to: directory)
        }
    }

    private func write(_ composition: Composition, named name: String, to directory: URL) throws {
        let url = directory.appendingPathComponent(name).appendingPathExtension("easel")
        try? FileManager.default.removeItem(at: url)
        try CompositionArchive.fileWrapper(for: composition).write(to: url, options: .atomic, originalContentsURL: nil)
    }

    // MARK: - Words

    /// The names and words in the documents, in English or Japanese.
    struct Words {
        let isJapanese: Bool

        func t(_ english: String, _ japanese: String) -> String { isJapanese ? japanese : english }

        var lakesideTitle: String { t("Lakeside Evening", "湖畔の夕暮れ") }
        var poppiesTitle: String { t("Poppy Study", "ポピーの習作") }
        var posterTitle: String { t("Summer Festival", "夏まつり") }
        var passportTitle: String { t("Passport Scan", "パスポートのスキャン") }
        var plushTitle: String { t("Plush Portrait", "ぬいぐるみの肖像") }
    }

    // MARK: - Lakeside Evening

    /// A sunset over a mountain lake, with pines on the near shore: the sky
    /// and sun in one group, the land and water in another.
    static func lakeside(_ words: Words) -> Composition {
        let size = size
        let horizon = 1180.0
        var random = SampleRandom(seed: 3)
        let background = LayerGroup(name: words.t("Background", "背景"))
        let scenery = LayerGroup(name: words.t("Scenery", "風景"))

        let sky = Bitmap.render(size: size) { context in
            fillGradient(context, in: CGRect(x: 0, y: 0, width: size.width, height: horizon + 4), stops: [
                (0, RGBAColor(red: 0.15, green: 0.12, blue: 0.38)),
                (0.38, RGBAColor(red: 0.47, green: 0.22, blue: 0.55)),
                (0.72, RGBAColor(red: 0.95, green: 0.43, blue: 0.47)),
                (1, RGBAColor(red: 1.0, green: 0.74, blue: 0.45)),
            ])
            // Long soft clouds catching the light from below.
            for index in 0..<7 {
                let y = 260 + Double(index) * 110 + random.next() * 50
                let x = -100 + random.next() * 500
                let length = 700 + random.next() * 700
                let color = index < 3
                    ? RGBAColor(red: 0.85, green: 0.45, blue: 0.70)
                    : RGBAColor(red: 1.0, green: 0.66, blue: 0.62)
                paint(context, wave(from: CGPoint(x: x, y: y), length: length, amplitude: 18, random: &random),
                      brush(size: 90 + random.next() * 70, color: color, opacity: 0.45, tip: .airbrush))
                paint(context, wave(from: CGPoint(x: x + 80, y: y + 22), length: length * 0.6, amplitude: 10, random: &random),
                      brush(size: 26, color: RGBAColor(red: 1, green: 0.85, blue: 0.75), opacity: 0.4, softness: 0.9, tip: .round), taper: true)
            }
        }

        let sunCenter = CGPoint(x: 1010, y: horizon - 70)
        let sun = Bitmap.render(size: size) { context in
            let colors = [
                RGBAColor(red: 1, green: 0.93, blue: 0.72, alpha: 0.9).cgColor,
                RGBAColor(red: 1, green: 0.70, blue: 0.45, alpha: 0.35).cgColor,
                RGBAColor(red: 1, green: 0.60, blue: 0.45, alpha: 0).cgColor,
            ] as CFArray
            if let glow = CGGradient(colorsSpace: Bitmap.colorSpace, colors: colors, locations: [0, 0.35, 1]) {
                context.drawRadialGradient(glow, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: 520, options: [])
            }
            context.setFillColor(RGBAColor(red: 1, green: 0.95, blue: 0.80).cgColor)
            context.fillEllipse(in: CGRect(x: sunCenter.x - 120, y: sunCenter.y - 120, width: 240, height: 240))
        }

        let farRidge = ridge(base: horizon, height: 430, roughness: 0.55, seed: 11, width: size.width)
        let farPeaks = Bitmap.render(size: size) { context in
            context.saveGState()
            context.addPath(farRidge)
            context.clip()
            fillGradient(context, in: CGRect(x: 0, y: horizon - 460, width: size.width, height: 470), stops: [
                (0, RGBAColor(red: 0.50, green: 0.30, blue: 0.56)),
                (1, RGBAColor(red: 0.86, green: 0.50, blue: 0.56)),
            ])
            // Snow on the high ground, laid on with a dry brush.
            for _ in 0..<26 {
                let x = random.next() * size.width
                let top = highest(farRidge, at: x)
                guard top < horizon - 260 else { continue }
                paint(context, [CGPoint(x: x, y: top + 6), CGPoint(x: x + 30 + random.next() * 40, y: top + 70 + random.next() * 60)],
                      brush(size: 18, color: RGBAColor(red: 1, green: 0.86, blue: 0.86), opacity: 0.45, tip: .chalk), taper: true)
            }
            context.restoreGState()
        }

        let nearRidge = ridge(base: horizon, height: 190, roughness: 0.4, seed: 23, width: size.width)
        let nearHills = Bitmap.render(size: size) { context in
            context.saveGState()
            context.addPath(nearRidge)
            context.clip()
            fillGradient(context, in: CGRect(x: 0, y: horizon - 200, width: size.width, height: 210), stops: [
                (0, RGBAColor(red: 0.26, green: 0.14, blue: 0.36)),
                (1, RGBAColor(red: 0.42, green: 0.20, blue: 0.40)),
            ])
            context.restoreGState()
        }

        let lake = Bitmap.render(size: size) { context in
            fillGradient(context, in: CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon), stops: [
                (0, RGBAColor(red: 0.93, green: 0.55, blue: 0.52)),
                (0.45, RGBAColor(red: 0.55, green: 0.27, blue: 0.50)),
                (1, RGBAColor(red: 0.16, green: 0.12, blue: 0.33)),
            ])
            // The hills, upside down in the water.
            context.saveGState()
            context.translateBy(x: 0, y: horizon * 2)
            context.scaleBy(x: 1, y: -1)
            context.addPath(nearRidge)
            context.setFillColor(RGBAColor(red: 0.30, green: 0.15, blue: 0.36, alpha: 0.55).cgColor)
            context.fillPath()
            context.restoreGState()
            // The sun's path across the water, broken by ripples.
            for index in 0..<34 {
                let y = horizon + 30 + Double(index) * 22 + random.next() * 8
                let half = (150 - Double(index) * 2.6) * (0.5 + random.next() * 0.7)
                let x = sunCenter.x + (random.next() - 0.5) * 40
                paint(context, [CGPoint(x: x - half, y: y), CGPoint(x: x + half, y: y)],
                      brush(size: 12 + random.next() * 8, color: RGBAColor(red: 1, green: 0.90, blue: 0.70), opacity: 0.8, tip: .chalk), taper: true)
            }
            for _ in 0..<60 {
                let y = horizon + 20 + random.next() * (size.height - horizon - 40)
                let x = random.next() * size.width
                let length = 60 + random.next() * 220
                paint(context, [CGPoint(x: x, y: y), CGPoint(x: x + length, y: y + random.next() * 4)],
                      brush(size: 6, color: .white, opacity: 0.25, softness: 0.8, tip: .round), taper: true)
            }
        }

        let pines = Bitmap.render(size: size) { context in
            let ink = RGBAColor(red: 0.08, green: 0.05, blue: 0.13)
            // The near shore, across the bottom left.
            let shore = CGMutablePath()
            shore.move(to: CGPoint(x: 0, y: 1640))
            shore.addCurve(to: CGPoint(x: 900, y: 1960), control1: CGPoint(x: 360, y: 1660), control2: CGPoint(x: 640, y: 1840))
            shore.addCurve(to: CGPoint(x: size.width, y: 1900), control1: CGPoint(x: 1150, y: 2060), control2: CGPoint(x: 1400, y: 1900))
            shore.addLine(to: CGPoint(x: size.width, y: size.height))
            shore.addLine(to: CGPoint(x: 0, y: size.height))
            shore.closeSubpath()
            context.addPath(shore)
            context.setFillColor(ink.cgColor)
            context.fillPath()
            let trees: [(x: Double, base: Double, height: Double)] = [
                (80, 1720, 760), (240, 1740, 900), (390, 1780, 680), (530, 1840, 520),
                (650, 1900, 380), (1340, 1950, 360), (1460, 1930, 480),
            ]
            for tree in trees {
                pine(context, x: tree.x, base: tree.base, height: tree.height, color: ink, random: &random)
            }
        }

        let birds = Bitmap.render(size: size) { context in
            let flock: [(CGPoint, Double)] = [
                (CGPoint(x: 700, y: 640), 40), (CGPoint(x: 780, y: 600), 30), (CGPoint(x: 840, y: 680), 26),
                (CGPoint(x: 600, y: 720), 22), (CGPoint(x: 905, y: 620), 18),
            ]
            for (center, span) in flock {
                paint(context, [
                    CGPoint(x: center.x - span, y: center.y - span * 0.35),
                    CGPoint(x: center.x - span * 0.45, y: center.y - span * 0.45),
                    center,
                    CGPoint(x: center.x + span * 0.45, y: center.y - span * 0.5),
                    CGPoint(x: center.x + span, y: center.y - span * 0.3),
                ], brush(size: 7, color: RGBAColor(red: 0.12, green: 0.07, blue: 0.18), opacity: 0.9, tip: .pencil), taper: true)
            }
        }

        let sketch = Bitmap.render(size: size) { context in
            context.addPath(farRidge)
            context.addPath(nearRidge)
            context.setStrokeColor(RGBAColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 0.6).cgColor)
            context.setLineWidth(4)
            context.strokePath()
        }

        var skyLayer = layer(words.t("Sky", "空"), sky, group: background)
        var curves = LayerFilter(kind: .curves)
        curves.curve = [0, 0.13, 0.5, 0.87, 1]
        var saturation = LayerFilter(kind: .saturation)
        saturation.amount = 0.25
        skyLayer.filters = [curves, saturation]
        var sunLayer = layer(words.t("Sun", "太陽"), sun, group: background)
        sunLayer.blendMode = .screen
        var farLayer = layer(words.t("Far Peaks", "遠くの山"), farPeaks, group: scenery)
        farLayer.opacity = 0.9
        var sketchLayer = layer(words.t("Sketch", "下描き"), sketch)
        sketchLayer.isVisible = false

        var composition = Composition(size: size, layers: [
            skyLayer, sunLayer,
            farLayer,
            layer(words.t("Near Hills", "手前の丘"), nearHills, group: scenery),
            layer(words.t("Lake", "湖"), lake, group: scenery),
            // The pines on top, so they are the layer the editor opens on.
            sketchLayer,
            layer(words.t("Birds", "鳥"), birds),
            layer(words.t("Pines", "松林"), pines),
        ], groups: [background, scenery])
        composition.swatches = [
            RGBAColor(red: 0.95, green: 0.43, blue: 0.47), RGBAColor(red: 1, green: 0.74, blue: 0.45),
            RGBAColor(red: 0.47, green: 0.22, blue: 0.55), RGBAColor(red: 0.08, green: 0.05, blue: 0.13),
        ]
        return composition
    }

    /// A pine in silhouette: a trunk and tiers of ragged boughs, each wider
    /// than the one above, with a dry brush run along their edges.
    private static func pine(
        _ context: CGContext, x: Double, base: Double, height: Double, color: RGBAColor, random: inout SampleRandom
    ) {
        let top = base - height
        paint(context, [CGPoint(x: x, y: base + 40), CGPoint(x: x, y: top + height * 0.3)],
              brush(size: max(6, height * 0.018), color: color, tip: .round))
        context.setFillColor(color.cgColor)
        let tiers = 7
        for tier in 0..<tiers {
            let t = Double(tier) / Double(tiers - 1)
            let apex = top + t * height * 0.62
            let bottom = apex + height * (0.2 + t * 0.1)
            let half = height * (0.06 + t * 0.15)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: apex))
            // Down the right edge and back along the bottom, ragged all the way.
            let teeth = 6
            for tooth in 1...teeth {
                let f = Double(tooth) / Double(teeth)
                path.addLine(to: CGPoint(x: x + half * f + random.next() * 10, y: apex + (bottom - apex) * f - 10 + random.next() * 6))
                path.addLine(to: CGPoint(x: x + half * f * 0.82, y: apex + (bottom - apex) * f - 2))
            }
            for tooth in stride(from: 8, through: -8, by: -1) {
                let f = Double(tooth) / 8
                path.addLine(to: CGPoint(x: x + half * f, y: bottom + (tooth.isMultiple(of: 2) ? 8 : -12) + random.next() * 8))
            }
            for tooth in stride(from: teeth, through: 1, by: -1) {
                let f = Double(tooth) / Double(teeth)
                path.addLine(to: CGPoint(x: x - half * f * 0.82, y: apex + (bottom - apex) * f - 2))
                path.addLine(to: CGPoint(x: x - half * f - random.next() * 10, y: apex + (bottom - apex) * f - 10 + random.next() * 6))
            }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
            for side in [-1.0, 1.0] {
                paint(context, [CGPoint(x: x, y: apex + 10), CGPoint(x: x + side * half, y: bottom + 4)],
                      brush(size: 14 + t * 10, color: color, opacity: 0.9, tip: .chalk), taper: true)
            }
        }
    }

    // MARK: - Poppy Study

    /// Poppies painted loosely over a pencil sketch on warm paper: watercolour
    /// petals, bristle leaves, dry-brushed stems, stippled centres and a
    /// spatter of paint.
    static func poppies(_ words: Words) -> Composition {
        let size = size
        var random = SampleRandom(seed: 5)
        let flowers: [(center: CGPoint, radius: Double, hue: RGBAColor)] = [
            (CGPoint(x: 560, y: 640), 230, RGBAColor(red: 0.90, green: 0.16, blue: 0.18)),
            (CGPoint(x: 1060, y: 900), 190, RGBAColor(red: 0.98, green: 0.45, blue: 0.16)),
            (CGPoint(x: 420, y: 1230), 160, RGBAColor(red: 0.93, green: 0.30, blue: 0.45)),
            (CGPoint(x: 1120, y: 1440), 120, RGBAColor(red: 0.98, green: 0.62, blue: 0.20)),
        ]
        let ground = CGPoint(x: 780, y: 1980)

        let paper = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0.98, green: 0.96, blue: 0.91).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(RGBAColor(red: 0.55, green: 0.45, blue: 0.35, alpha: 0.10).cgColor)
            for _ in 0..<26000 {
                let radius = 0.8 + random.next() * 1.6
                context.fillEllipse(in: CGRect(x: random.next() * size.width, y: random.next() * size.height, width: radius, height: radius))
            }
        }

        let sketch = Bitmap.render(size: size) { context in
            let graphite = brush(size: 5, color: RGBAColor(red: 0.25, green: 0.23, blue: 0.24), opacity: 0.55, tip: .pencil)
            for flower in flowers {
                for petal in 0..<5 {
                    let angle = Double(petal) / 5 * 2 * .pi + 0.3
                    paint(context, arc(center: flower.center, radius: flower.radius * 0.95, from: angle - 0.6, to: angle + 0.6, wobble: 14, random: &random), graphite)
                }
                paint(context, stem(from: flower.center, to: ground, radius: flower.radius), graphite)
            }
        }

        let stems = Bitmap.render(size: size) { context in
            for flower in flowers {
                paint(context, stem(from: flower.center, to: ground, radius: flower.radius),
                      brush(size: 30, color: RGBAColor(red: 0.30, green: 0.52, blue: 0.28), tip: .dryBrush))
            }
        }

        let leaves = Bitmap.render(size: size) { context in
            let greens = [
                RGBAColor(red: 0.36, green: 0.60, blue: 0.30), RGBAColor(red: 0.22, green: 0.45, blue: 0.30),
                RGBAColor(red: 0.55, green: 0.70, blue: 0.35),
            ]
            for index in 0..<14 {
                let start = CGPoint(x: ground.x + (random.next() - 0.5) * 200, y: ground.y - random.next() * 220)
                let side = index.isMultiple(of: 2) ? -1.0 : 1.0
                let length = 260 + random.next() * 360
                let end = CGPoint(x: start.x + side * length * 0.8, y: start.y - length * (0.5 + random.next() * 0.5))
                let middle = CGPoint(x: (start.x + end.x) / 2 + side * 60, y: (start.y + end.y) / 2 + 70)
                paint(context, [start, middle, end], brush(size: 60 + random.next() * 30, color: greens[index % 3], opacity: 0.85, tip: .bristle), taper: true)
            }
        }

        let petals = Bitmap.render(size: size) { context in
            for flower in flowers {
                // Broad washes from the middle out, layered so they darken
                // where they cross.
                for layerIndex in 0..<3 {
                    for petal in 0..<9 {
                        let angle = Double(petal) / 9 * 2 * .pi + Double(layerIndex) * 0.35 + random.next() * 0.2
                        let reach = flower.radius * (0.75 + random.next() * 0.3)
                        let from = CGPoint(x: flower.center.x + cos(angle) * flower.radius * 0.15, y: flower.center.y + sin(angle) * flower.radius * 0.15)
                        let bend = angle + (random.next() - 0.5) * 0.5
                        let to = CGPoint(x: flower.center.x + cos(bend) * reach, y: flower.center.y + sin(bend) * reach)
                        let middle = CGPoint(x: (from.x + to.x) / 2 + (random.next() - 0.5) * 40, y: (from.y + to.y) / 2 + (random.next() - 0.5) * 40)
                        let shade = flower.hue.mixed(with: layerIndex == 2 ? RGBAColor(red: 1, green: 0.85, blue: 0.7) : .black, by: layerIndex == 1 ? 0.15 : 0.1 * Double(layerIndex))
                        paint(context, [from, middle, to], brush(size: flower.radius * (0.55 - Double(layerIndex) * 0.12), color: shade, opacity: 0.6, softness: 0.3, tip: .watercolor))
                    }
                }
            }
        }

        let centres = Bitmap.render(size: size) { context in
            for flower in flowers {
                let r = flower.radius * 0.2
                context.setFillColor(RGBAColor(red: 0.13, green: 0.10, blue: 0.14).cgColor)
                context.fillEllipse(in: CGRect(x: flower.center.x - r, y: flower.center.y - r, width: r * 2, height: r * 2))
                // A ring of stippled stamens round the middle.
                paint(context, arc(center: flower.center, radius: r * 1.4, from: 0, to: 2 * .pi, wobble: 0, random: &random),
                      brush(size: r * 0.7, color: RGBAColor(red: 0.15, green: 0.10, blue: 0.15), opacity: 0.9, tip: .stipple))
            }
        }

        let shading = Bitmap.render(size: size) { context in
            for flower in flowers {
                paint(context, arc(center: flower.center, radius: flower.radius * 0.55, from: 0.4, to: 2.6, wobble: 0, random: &random),
                      brush(size: flower.radius * 0.5, color: RGBAColor(red: 0.45, green: 0.05, blue: 0.15), opacity: 0.35, tip: .airbrush))
            }
        }

        let splashes = Bitmap.render(size: size) { context in
            let colors = flowers.map(\.hue) + [RGBAColor(red: 0.36, green: 0.60, blue: 0.30)]
            // Flicks of each colour across the page.
            for color in colors + colors {
                let start = CGPoint(x: 150 + random.next() * (size.width - 300), y: 200 + random.next() * (size.height - 400))
                let end = CGPoint(x: start.x + (random.next() - 0.5) * 500, y: start.y + (random.next() - 0.5) * 300)
                paint(context, [start, end], brush(size: 110, color: color, opacity: 0.75, tip: .spatter))
            }
        }

        var shadingLayer = layer(words.t("Shading", "陰影"), shading)
        shadingLayer.blendMode = .multiply
        var sketchLayer = layer(words.t("Sketch", "下描き"), sketch)
        sketchLayer.opacity = 0.7
        var composition = Composition(size: size, layers: [
            layer(words.t("Paper", "紙"), paper),
            sketchLayer,
            layer(words.t("Leaves", "葉"), leaves),
            layer(words.t("Stems", "茎"), stems),
            layer(words.t("Petals", "花びら"), petals),
            shadingLayer,
            layer(words.t("Centres", "花芯"), centres),
            layer(words.t("Splashes", "しぶき"), splashes),
        ])
        composition.swatches = flowers.map(\.hue) + [RGBAColor(red: 0.30, green: 0.52, blue: 0.28)]
        return composition
    }

    private static func stem(from flower: CGPoint, to ground: CGPoint, radius: Double) -> [CGPoint] {
        let start = CGPoint(x: flower.x, y: flower.y + radius * 0.2)
        let middle = CGPoint(x: (flower.x * 0.4 + ground.x * 0.6) + (flower.x < ground.x ? -40 : 40), y: (flower.y + ground.y) / 2)
        return [start, middle, ground]
    }

    // MARK: - Summer Festival poster

    /// A poster: a sun and waves as vector paths, a title and date as text,
    /// and a line of text set along an arc over the sun.
    static func poster(_ words: Words) -> Composition {
        let size = size
        var random = SampleRandom(seed: 9)
        let background = Bitmap.render(size: size) { context in
            fillGradient(context, in: CGRect(origin: .zero, size: size), stops: [
                (0, RGBAColor(red: 0.18, green: 0.62, blue: 0.86)),
                (0.6, RGBAColor(red: 0.50, green: 0.82, blue: 0.93)),
                (1, RGBAColor(red: 0.98, green: 0.90, blue: 0.75)),
            ])
            for _ in 0..<40 {
                let center = CGPoint(x: random.next() * size.width, y: random.next() * size.height * 0.55)
                let radius = 2 + random.next() * 5
                context.setFillColor(RGBAColor.white.withAlpha(0.6).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }

        let sunRect = CGRect(x: 468, y: 900, width: 600, height: 600)
        let sun = Layer.vector(VectorPath.shape(ShapeSpec(
            kind: .ellipse, start: sunRect.origin, end: CGPoint(x: sunRect.maxX, y: sunRect.maxY),
            isFilled: true, lineWidth: 0, color: RGBAColor(red: 1, green: 0.78, blue: 0.25)
        )), name: words.t("Sun", "太陽"))

        func wave(top: Double, amplitude: Double, phase: Double, color: RGBAColor) -> VectorPath {
            let count = 5
            let step = (size.width + 200) / Double(count)
            var nodes: [VectorNode] = []
            for index in 0...count {
                let x = -100 + Double(index) * step
                let y = top + (index.isMultiple(of: 2) ? -amplitude : amplitude) * (phase > 0 ? 1 : -1)
                nodes.append(.smooth(at: CGPoint(x: x, y: y), handle: CGPoint(x: x + step * 0.4, y: y)))
            }
            nodes.append(VectorNode(point: CGPoint(x: size.width + 100, y: size.height + 10)))
            nodes.append(VectorNode(point: CGPoint(x: -100, y: size.height + 10)))
            return VectorPath(nodes: nodes, isClosed: true, fill: color, stroke: nil, strokeWidth: 0)
        }
        let waves = Layer.vector([
            wave(top: 1400, amplitude: 50, phase: 1, color: RGBAColor(red: 0.12, green: 0.45, blue: 0.80)),
            wave(top: 1560, amplitude: 60, phase: -1, color: RGBAColor(red: 0.07, green: 0.33, blue: 0.68)),
            wave(top: 1730, amplitude: 45, phase: 1, color: RGBAColor(red: 0.04, green: 0.22, blue: 0.52)),
        ], name: words.t("Waves", "波"))

        let arcCenter = CGPoint(x: sunRect.midX, y: sunRect.midY)
        let arcRadius = sunRect.width / 2 + 80
        let arcPath = VectorPath(
            nodes: [
                .smooth(at: CGPoint(x: arcCenter.x - arcRadius, y: arcCenter.y), handle: CGPoint(x: arcCenter.x - arcRadius, y: arcCenter.y - arcRadius * 0.55)),
                .smooth(at: CGPoint(x: arcCenter.x, y: arcCenter.y - arcRadius), handle: CGPoint(x: arcCenter.x + arcRadius * 0.55, y: arcCenter.y - arcRadius)),
                VectorNode(point: CGPoint(x: arcCenter.x + arcRadius, y: arcCenter.y), controlIn: CGPoint(x: arcCenter.x + arcRadius, y: arcCenter.y - arcRadius * 0.55)),
            ],
            isClosed: false, fill: nil, stroke: nil, strokeWidth: 0,
            text: PathText(string: words.t("MUSIC · FOOD · FIREWORKS", "音楽 ・ 屋台 ・ 花火"), fontSize: 64, color: .white, start: 0.12)
        )
        let tagline = Layer.vector([arcPath], name: words.t("Tagline", "キャッチコピー"))

        let title = text(
            TextContent(
                string: words.t("Summer\nFestival", "夏まつり"), design: .rounded, isBold: true,
                fontSize: words.isJapanese ? 270 : 220, color: .white,
                outline: TextContent.Outline(color: RGBAColor(red: 0.04, green: 0.22, blue: 0.52), width: 0.06)
            ),
            at: CGPoint(x: size.width / 2, y: 380)
        )
        let date = text(
            TextContent(
                string: words.t("Wildhunt Academy", "ワイルドハント学園"), design: .rounded, isBold: true,
                fontSize: 72, color: RGBAColor(red: 0.04, green: 0.22, blue: 0.52),
                background: TextContent.Background(color: RGBAColor(red: 1, green: 0.95, blue: 0.82), padding: 0.45, cornerRadius: 1)
            ),
            at: CGPoint(x: size.width / 2, y: 1880)
        )

        var composition = Composition(size: size, layers: [
            // The tagline on top, so it is the layer the editor opens on.
            layer(words.t("Background", "背景"), background), sun, waves, title, date, tagline,
        ])
        composition.swatches = [
            RGBAColor(red: 1, green: 0.78, blue: 0.25), RGBAColor(red: 0.12, green: 0.45, blue: 0.80),
            RGBAColor(red: 0.04, green: 0.22, blue: 0.52), .white,
        ]
        return composition
    }

    private static func text(_ content: TextContent, at point: CGPoint) -> Layer {
        let name = content.string.split(separator: "\n").map(String.init).joined(separator: " ")
        return Layer(
            name: name, image: LayerImage(TextRenderer.render(content)), text: content,
            transform: LayerTransform(position: point)
        )
    }

    // MARK: - Plush Portrait

    /// A chibi plush drawn as a flat 2D illustration: every part a clean
    /// shape of ovals and smooth curves, filled flat and inked round, with
    /// cel shadows, blush and highlights over them and the construction
    /// sketch kept, hidden, underneath. Laid out on a 750-wide grid.
    static func plush(_ words: Words) -> Composition {
        let size = CGSize(width: 1536, height: 1755)
        let scale = size.width / 750
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

        /// A closed, smooth curve through the points, with no corners.
        func blob(_ points: [(Double, Double)]) -> CGPath {
            let pts = points.map { p($0.0, $0.1) }
            let path = CGMutablePath()
            path.move(to: pts[0])
            for index in pts.indices {
                let p0 = pts[(index - 1 + pts.count) % pts.count], p1 = pts[index]
                let p2 = pts[(index + 1) % pts.count], p3 = pts[(index + 2) % pts.count]
                path.addCurve(
                    to: p2,
                    control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                    control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                )
            }
            path.closeSubpath()
            return path
        }
        /// An open, smooth curve through the points.
        func curve(_ points: [(Double, Double)]) -> CGPath {
            let pts = points.map { p($0.0, $0.1) }
            let path = CGMutablePath()
            path.move(to: pts[0])
            for index in 0..<(pts.count - 1) {
                let p0 = pts[max(0, index - 1)], p1 = pts[index]
                let p2 = pts[index + 1], p3 = pts[min(pts.count - 1, index + 2)]
                path.addCurve(
                    to: p2,
                    control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                    control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                )
            }
            return path
        }
        func oval(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, turned degrees: Double = 0) -> CGPath {
            var transform = CGAffineTransform(translationX: x * scale, y: y * scale).rotated(by: degrees * .pi / 180)
            return CGPath(ellipseIn: CGRect(x: -rx * scale, y: -ry * scale, width: rx * 2 * scale, height: ry * 2 * scale), transform: &transform)
        }
        func hex(_ value: UInt32) -> RGBAColor {
            RGBAColor(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }

        let ink = hex(0x3A2B3F)
        let white = hex(0xF7F8FC), skin = hex(0xF6DFD3), pink = hex(0xE0559A)
        let navy = hex(0x3B3A4D), denim = hex(0x9DBCE6), tie = hex(0x4C9CE6), shadowTone = hex(0xE3DEF4)
        let seam = hex(0xB8BBC9), lash = hex(0x4A2A30)

        /// Fills a shape and inks round it.
        func shape(_ context: CGContext, _ path: CGPath, _ fill: RGBAColor?, line: Double = 8, ink lineColor: RGBAColor? = nil) {
            if let fill {
                context.addPath(path)
                context.setFillColor(fill.cgColor)
                context.fillPath()
            }
            guard line > 0 else { return }
            stroke(context, path, lineColor ?? ink, width: line)
        }
        /// A polygon with its corners rounded off.
        func rounded(_ points: [(Double, Double)], radius: Double) -> CGPath {
            let pts = points.map { p($0.0, $0.1) }
            let path = CGMutablePath()
            let start = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
            path.move(to: start)
            for index in 1...pts.count {
                path.addArc(tangent1End: pts[index % pts.count], tangent2End: pts[(index + 1) % pts.count], radius: radius * scale)
            }
            path.closeSubpath()
            return path
        }
        func stroke(_ context: CGContext, _ path: CGPath, _ color: RGBAColor, width: Double) {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }

        // The parts, back to front.
        // Its top is the hood's edge: nothing of the hair shows above it.
        let hoodEdge: [(Double, Double)] = [(173, 348), (193, 242), (263, 175), (336, 150), (409, 156), (487, 195), (543, 253), (571, 315), (577, 350)]
        let hairBack = blob(hoodEdge.dropFirst().dropLast() + [
            (580, 370), (592, 470), (622, 590), (640, 700), (592, 712), (548, 610), (375, 590), (202, 610),
            (158, 712), (110, 700), (128, 590), (158, 470), (168, 370),
        ])
        let face = blob([
            (225, 330), (300, 300), (375, 295), (450, 300), (528, 330), (548, 420), (530, 490),
            (460, 532), (375, 548), (290, 532), (220, 490), (204, 420),
        ])
        let jacket = blob([
            (220, 540), (300, 522), (375, 532), (450, 522), (530, 540), (600, 585), (640, 645), (618, 692),
            (555, 700), (375, 712), (195, 700), (132, 692), (110, 645), (150, 585),
        ])
        let skirt = blob([(305, 680), (445, 680), (470, 785), (375, 808), (280, 785)])
        let vest = blob([(305, 545), (375, 568), (445, 545), (458, 640), (420, 700), (375, 712), (330, 700), (292, 640)])
        let leftFoot = oval(262, 738, 72, 94, turned: -8)
        let rightFoot = oval(488, 738, 72, 94, turned: 8)
        // Cuffs: long dark bands slanting with the ends of the sleeves, down
        // from the outside towards the body, measured off the photo.
        let leftCuff = rounded([(106, 636), (123, 623), (185, 693), (163, 705)], radius: 4)
        let rightCuff = rounded([(626, 612), (652, 624), (592, 687), (580, 673)], radius: 4)
        let leftHand = oval(132, 674, 19, 18), rightHand = oval(640, 658, 22, 20)
        // The fringe parts in the middle and sweeps down each side, leaving
        // the face showing under an upturned V.
        let fringe = blob([
            (188, 330), (212, 240), (268, 180), (336, 154), (420, 158), (490, 192), (545, 252), (566, 330),
            (540, 378), (484, 340), (423, 304), (336, 304), (270, 338), (214, 378),
        ])
        // The long strand from the crown, straight down between the eyes and
        // then sweeping left under the left one.
        let strand = blob([
            (336, 155), (332, 300), (329, 400), (318, 452), (290, 490), (246, 520), (262, 523), (320, 500), (372, 460), (398, 400),
            (420, 315), (423, 164), (380, 150),
        ])
        let leftLock = blob([(206, 340), (222, 400), (230, 470), (224, 532), (204, 500), (190, 420)])
        // The right lock curls in to a point by the chin.
        let rightLock = blob([(546, 330), (540, 400), (532, 470), (512, 528), (494, 540), (526, 542), (554, 500), (566, 420)])
        let bangParts = [fringe, strand, leftLock, rightLock]

        let paper = Bitmap.solid(size: size, color: hex(0xFCE4EB))
        var random = SampleRandom(seed: 21)
        let pattern = Bitmap.render(size: size) { context in
            for _ in 0..<36 {
                let center = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
                let radius = 8 + random.next() * 16
                let color = [hex(0xFFC4D3), hex(0xD4DCFF), RGBAColor.white][Int(random.next() * 3) % 3]
                context.setFillColor(color.cgColor)
                if random.next() < 0.35 {
                    let star = CGMutablePath()
                    for point in 0..<10 {
                        let angle = Double(point) * .pi / 5 - .pi / 2
                        let r = point.isMultiple(of: 2) ? radius * 1.6 : radius * 0.7
                        let q = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                        if point == 0 { star.move(to: q) } else { star.addLine(to: q) }
                    }
                    star.closeSubpath()
                    context.addPath(star)
                    context.fillPath()
                } else {
                    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }
            }
            // A soft shadow for the plush to sit on.
            context.addPath(oval(375, 828, 270, 26))
            context.setFillColor(hex(0xD9A9BB).withAlpha(0.5).cgColor)
            context.fillPath()
        }

        // Kei's halo, as the game draws it: glowing pink outlined frames
        // with nothing inside them, the right-hand ones leaning back a
        // little. Measured off her art on a 1000-wide crop and fitted over
        // the plush's head where the felt halo sits.
        let halo = Bitmap.render(size: size) { context in
            func h(_ x: Double, _ y: Double) -> CGPoint { p(332 + (x - 95) * 0.425, 60 + (y - 35) * 0.425) }
            func outline(_ points: [(Double, Double)], into path: CGMutablePath) {
                path.addLines(between: points.map { h($0.0, $0.1) })
                path.closeSubpath()
            }
            // Each frame is its outside edge and the holes cut from it.
            let frames: [(outside: [(Double, Double)], holes: [[(Double, Double)]])] = [
                // The small box, top left.
                ([(130, 62), (255, 57), (258, 115), (133, 118)], [[(152, 75), (237, 72), (239, 100), (154, 103)]]),
                // The tall frame on the left, split down the middle.
                ([(95, 140), (455, 140), (455, 520), (95, 520)], [[(125, 170), (345, 170), (345, 520), (125, 520)], [(385, 170), (428, 170), (428, 520), (385, 520)]]),
                // The big frame on the right.
                ([(350, 35), (820, 55), (790, 522), (350, 510)], [[(385, 85), (778, 95), (752, 492), (385, 482)]]),
                // The low frame overlapping it, with a slot across its top.
                ([(465, 420), (698, 430), (690, 665), (460, 660)], [[(495, 455), (665, 463), (662, 486), (497, 481)], [(497, 503), (662, 508), (657, 640), (493, 636)]]),
            ]
            // The tab hanging from the big frame's top.
            let tab = CGMutablePath()
            outline([(475, 85), (585, 88), (583, 140), (477, 137)], into: tab)

            func fillFrames(_ color: RGBAColor) {
                context.setFillColor(color.cgColor)
                // Each frame is cut on its own, so overlapping frames do not
                // punch holes in one another.
                for frame in frames {
                    let piece = CGMutablePath()
                    outline(frame.outside, into: piece)
                    for hole in frame.holes { outline(hole, into: piece) }
                    context.addPath(piece)
                    context.fillPath(using: .evenOdd)
                }
                context.addPath(tab)
                context.fillPath()
            }
            // A soft glow round the lines, then the lines themselves.
            context.saveGState()
            context.setShadow(offset: .zero, blur: 14 * scale, color: hex(0xFF5FAE).cgColor)
            fillFrames(hex(0xF2649F))
            context.restoreGState()
            fillFrames(hex(0xF46FAB))
        }

        let hairBackLayer = Bitmap.render(size: size) { context in
            shape(context, hairBack, white)
        }

        let body = Bitmap.render(size: size) { context in
            shape(context, skirt, hex(0x2F2E3E))
            stroke(context, curve([(286, 778), (330, 792), (375, 798), (420, 792), (464, 778)]), tie, width: 5 * scale)
            shape(context, jacket, white)
            // Cuffs, with a pink mark each, and the hands peeking out.
            // Two dark stripes over each shoulder.
            for (from, to) in [((199.0, 547.0), (225.0, 592.0)), ((218, 544), (244, 589)), ((551, 547), (525, 592)), ((532, 544), (506, 589))] {
                stroke(context, curve([from, to]), navy, width: 5 * scale)
            }
            // Cuffs, each with a pink tag, and the hands peeking out.
            // Each band has a seam across its top and a pink tag lying along it.
            for (cuff, tag, along, seamLine, hand) in [
                (leftCuff, (136.0, 659.0), 49.4, [(133.0, 643.0), (119, 652)], leftHand),
                (rightCuff, (610.0, 648.0), 130.5, [(617.0, 629.0), (631, 640)], rightHand),
            ] {
                shape(context, hand, skin)
                shape(context, cuff, navy)
                stroke(context, curve(seamLine), hex(0x26252F), width: 2 * scale)
                context.saveGState()
                context.translateBy(x: tag.0 * scale, y: tag.1 * scale)
                context.rotate(by: along * .pi / 180)
                context.setFillColor(hex(0xC8336E).cgColor)
                context.fill(CGRect(x: -7.5 * scale, y: -3.5 * scale, width: 15 * scale, height: 7 * scale))
                context.restoreGState()
            }
            shape(context, blob([(330, 530), (375, 548), (420, 530), (400, 572), (375, 580), (350, 572)]), white, line: 5)
            shape(context, vest, navy)
            for y in [604.0, 622, 641] {
                context.addPath(oval(379, y, 4.5, 4.5))
                context.setFillColor(hex(0x6B6A80).cgColor)
                context.fillPath()
            }
            shape(context, blob([(366, 548), (384, 548), (392, 566), (375, 590), (358, 566)]), tie, line: 5)
            // The hood's white edge folds down each side of the vest, with a
            // pink band where it meets the collar.
            shape(context, blob([(292, 528), (318, 526), (346, 596), (340, 664), (324, 646), (300, 584)]), white, line: 6)
            shape(context, blob([(458, 528), (432, 526), (404, 596), (410, 664), (426, 646), (450, 584)]), white, line: 6)
            stroke(context, curve([(280, 546), (306, 568)]), pink, width: 9 * scale)
            stroke(context, curve([(470, 546), (444, 568)]), pink, width: 9 * scale)
            for foot in [leftFoot, rightFoot] {
                shape(context, foot, denim, line: 10)
            }
            shape(context, oval(262, 738, 50, 70, turned: -8), hex(0xB4CDEE), line: 0)
            shape(context, oval(488, 738, 50, 70, turned: 8), hex(0xB4CDEE), line: 0)
        }

        let faceLayer = Bitmap.render(size: size) { context in
            shape(context, face, skin)
            // Brows and the small, straight mouth.
            stroke(context, curve([(269, 356), (300, 352), (330, 355)]), hex(0xB4B4C2), width: 4 * scale)
            stroke(context, curve([(417, 355), (450, 352), (481, 357)]), hex(0xB4B4C2), width: 4 * scale)
            stroke(context, curve([(367, 479), (379, 479)]), hex(0x8E3A4A), width: 4 * scale)
        }

        // The eyes, measured off the photo. They are not mirror images:
        // the left shows more white at its outer corner.
        let lashBrown = hex(0x4E2A2C), maroon = hex(0x7A2440)
        let eyes = Bitmap.render(size: size) { context in
            for eye in [
                (white: [(232.0, 400.0), (260, 396), (296, 396), (330, 400), (330, 440), (318, 457), (296, 459), (272, 457), (255, 440)],
                 iris: (296.0, 429.0),
                 lash: [(227.0, 396.0), (250, 388), (275, 383), (300, 381), (332, 386), (332, 397), (300, 395), (270, 397), (248, 402)],
                 spike: [(272.0, 386.0), (277, 378), (281, 385)],
                 tick: (298.0, 394.0),
                 crease: [(291.0, 378.0), (312, 381), (330, 388)],
                 corner: [(236.0, 399.0), (246, 420), (256, 438)]),
                (white: [(418.0, 402.0), (440, 397), (470, 396), (491, 400), (489, 440), (476, 458), (452, 460), (428, 458), (420, 440)],
                 iris: (452.0, 430.0),
                 lash: [(414.0, 408.0), (418, 395), (440, 386), (465, 382), (488, 386), (496, 395), (482, 398), (455, 397), (430, 400), (421, 409)],
                 spike: [(471.0, 384.0), (476, 376), (480, 384)],
                 tick: (452.0, 395.0),
                 crease: [(419.0, 389.0), (438, 382), (457, 379)],
                 corner: [(493.0, 399.0), (490, 420), (482, 440)]),
            ] {
                let (x, y) = eye.iris
                shape(context, blob(eye.white), .white, line: 0)
                /// A rounded box: the iris and its rings run straight down the
                /// sides into a flat bottom, as the embroidery does.
                func box(_ cx: Double, _ cy: Double, _ hw: Double, _ hh: Double, corner: Double) -> CGPath {
                    CGPath(roundedRect: CGRect(x: (cx - hw) * scale, y: (cy - hh) * scale, width: hw * 2 * scale, height: hh * 2 * scale),
                           cornerWidth: corner * scale, cornerHeight: corner * scale, transform: nil)
                }
                // Its top tucks up under the lash.
                let iris = box(x, y - 4, 30, 32, corner: 15)
                context.saveGState()
                context.addPath(blob(eye.white))
                context.clip()
                context.saveGState()
                context.addPath(iris)
                context.clip()
                // Deep magenta above, fading to pale pink below.
                context.setFillColor(hex(0xD93A86).cgColor)
                context.addPath(iris)
                context.fillPath()
                context.setFillColor(hex(0xF8C6D8).cgColor)
                context.addPath(blob([(x - 34, y + 2), (x - 12, y - 2), (x + 12, y - 2), (x + 34, y + 2), (x + 34, y + 34), (x - 34, y + 34)]))
                context.fillPath()
                // Concentric rings round a pale pupil set high in the iris:
                // light lines through the magenta, pink ones through the pale.
                for (hw, hh) in [(22.0, 22.0), (14, 15)] {
                    let ring = box(x + 2, y - 3, hw, hh, corner: hw * 0.95)
                    context.saveGState()
                    context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: (y + 1) * scale))
                    stroke(context, ring, hex(0xFBD3E2), width: 2.2 * scale)
                    context.restoreGState()
                    context.saveGState()
                    context.clip(to: CGRect(x: 0, y: (y + 1) * scale, width: size.width, height: size.height))
                    stroke(context, ring, hex(0xE88AB0), width: 2.2 * scale)
                    context.restoreGState()
                }
                shape(context, oval(x + 2, y - 8, 8, 9), hex(0xF9DCE5), line: 0)
                context.restoreGState()
                stroke(context, iris, maroon, width: 2.5 * scale)
                context.restoreGState()
                // The lash: a heavy band tapering to the outer corner, with a
                // small spike, a pink tick on it and a crease above.
                shape(context, blob(eye.lash), lashBrown, line: 0)
                context.addPath(CGPath(roundedRect: CGRect(x: (eye.tick.0 - 9) * scale, y: (eye.tick.1 - 3.5) * scale, width: 18 * scale, height: 7 * scale),
                                       cornerWidth: 3.5 * scale, cornerHeight: 3.5 * scale, transform: nil))
                context.setFillColor(hex(0xE8458F).cgColor)
                context.fillPath()
                let spike = CGMutablePath()
                spike.addLines(between: eye.spike.map { p($0.0, $0.1) })
                spike.closeSubpath()
                context.addPath(spike)
                context.setFillColor(lashBrown.cgColor)
                context.fillPath()
                stroke(context, curve(eye.crease), hex(0x6B2A33), width: 2.5 * scale)
                stroke(context, curve(eye.corner), lashBrown, width: 4 * scale)
            }
        }

        let bangs = Bitmap.render(size: size) { context in
            for part in [leftLock, rightLock, fringe, strand] { shape(context, part, white) }
            // Grey seams stitched through the hair.
            stroke(context, curve([(218, 343), (260, 285), (330, 226)]), seam, width: 3 * scale)
            stroke(context, curve([(224, 300), (256, 278), (292, 268)]), seam, width: 3 * scale)
            stroke(context, curve([(481, 236), (520, 287), (537, 360)]), seam, width: 3 * scale)
            // The thin dark edge of the hood, round the top of the head.
            stroke(context, curve(hoodEdge), navy, width: 7 * scale)
        }

        /// Where `part` shows, with `covers` drawn over it: what a shadow on
        /// the part may darken, as a mask to clip to.
        func showing(_ part: CGPath, under covers: [CGPath]) -> CGImage {
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            // Drawn the same way up as everything else.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(part)
            context.fillPath()
            context.setFillColor(gray: 0, alpha: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(8)
            for cover in covers {
                context.addPath(cover)
                context.fillPath()
                // The ink round a cover sits over the part too.
                context.addPath(cover)
                context.strokePath()
            }
            return context.makeImage()!
        }
        let shading = Bitmap.render(size: size) { context in
            func shadow(_ shapes: [CGPath], on part: CGPath, under covers: [CGPath]) {
                let mask = showing(part, under: covers)
                context.saveGState()
                // A clipping mask is laid down unflipped, so it is flipped
                // here to land the right way up.
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: CGRect(origin: .zero, size: size), mask: mask)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -size.height)
                context.setFillColor(shadowTone.cgColor)
                for shape in shapes { context.addPath(shape) }
                context.fillPath()
                context.restoreGState()
            }
            // Under the fringe, across the top of the face.
            shadow([blob([(206, 372), (270, 346), (336, 312), (375, 308), (423, 312), (484, 348), (546, 372), (542, 390), (484, 364), (423, 330), (336, 330), (270, 364), (210, 390)])],
                   on: face, under: bangParts)
            // Inside the hair, beside the face.
            shadow([blob([(176, 460), (194, 540), (204, 600), (172, 606), (164, 520)]), blob([(574, 460), (556, 540), (546, 600), (578, 606), (586, 520)])],
                   on: hairBack, under: [face, jacket, leftFoot, rightFoot] + bangParts)
            // Folds in the jacket.
            shadow([blob([(176, 660), (230, 640), (250, 672), (210, 698), (170, 690)]), blob([(574, 660), (520, 640), (500, 672), (540, 698), (580, 690)])],
                   on: jacket, under: [leftCuff, rightCuff, leftHand, rightHand, vest, leftFoot, rightFoot])
            // The undersides of the feet.
            for foot in [leftFoot, rightFoot] {
                shadow([oval(375, 860, 300, 70)], on: foot, under: [])
            }
        }
        let silhouette = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            for part in [hairBack, jacket, skirt, leftFoot, rightFoot, face] {
                context.addPath(part)
                context.fillPath()
            }
        }

        let blush = Bitmap.render(size: size) { context in
            for x in [280.0, 466] {
                context.addPath(oval(x, 474, 22, 14))
                context.setFillColor(hex(0xF7A3B7).cgColor)
                context.fillPath()
                // Two short red stitches in each.
                for dx in [-5.0, 5] {
                    stroke(context, curve([(x + dx, 467), (x + dx - 1, 481)]), hex(0xE0506A), width: 2.5 * scale)
                }
            }
        }

        let highlights = Bitmap.render(size: size) { context in
            stroke(context, curve([(300, 200), (345, 182), (395, 178)]), .white, width: 6 * scale)
            stroke(context, curve([(250, 238), (268, 222)]), .white, width: 6 * scale)
            for (x, turn) in [(238.0, -8.0), (464, 8)] {
                context.addPath(oval(x, 690, 14, 24, turned: turn))
            }
            context.setFillColor(RGBAColor.white.withAlpha(0.7).cgColor)
            context.fillPath()
        }

        // The pencil construction underneath: head and body ovals, a centre
        // line and an eye line, as the drawing was laid out.
        let sketch = Bitmap.render(size: size) { context in
            let graphite = brush(size: 4, color: hex(0x55555F), opacity: 0.7, tip: .pencil)
            for guide in [oval(375, 400, 215, 200), oval(375, 640, 250, 90), leftFoot, rightFoot] {
                var points: [CGPoint] = []
                guide.applyWithBlock { element in
                    let e = element.pointee
                    if e.type == .addCurveToPoint { points.append(e.points[2]) } else if e.type == .moveToPoint { points.append(e.points[0]) }
                }
                paint(context, points + [points[0]], graphite, canvasSize: size)
            }
            paint(context, [p(375, 180), p(375, 820)], graphite, canvasSize: size)
            paint(context, [p(180, 432), p(570, 432)], graphite, canvasSize: size)
        }

        let background = LayerGroup(name: words.t("Background", "背景"))
        let figure = LayerGroup(name: words.t("Plush", "ぬいぐるみ"))
        func layer(_ name: String, _ image: CGImage, group: LayerGroup) -> Layer {
            var layer = Layer(name: name, image: LayerImage(image), canvasSize: size)
            layer.groupID = group.id
            return layer
        }
        var shadingLayer = layer(words.t("Shading", "影"), shading, group: figure)
        shadingLayer.blendMode = .multiply
        shadingLayer.mask = LayerMask(image: LayerImage(silhouette))
        var sketchLayer = layer(words.t("Sketch", "下描き"), sketch, group: figure)
        sketchLayer.isVisible = false

        var composition = Composition(size: size, layers: [
            layer(words.t("Paper", "紙"), paper, group: background),
            layer(words.t("Pattern", "模様"), pattern, group: background),
            sketchLayer,
            layer(words.t("Halo", "ヘイロー"), halo, group: figure),
            layer(words.t("Back Hair", "後ろ髪"), hairBackLayer, group: figure),
            layer(words.t("Body", "体"), body, group: figure),
            layer(words.t("Face", "顔"), faceLayer, group: figure),
            layer(words.t("Eyes", "目"), eyes, group: figure),
            layer(words.t("Bangs", "前髪"), bangs, group: figure),
            layer(words.t("Blush", "チーク"), blush, group: figure),
            shadingLayer,
            layer(words.t("Highlights", "ハイライト"), highlights, group: figure),
        ], groups: [background, figure])
        composition.swatches = [white, skin, pink, navy, denim, tie]
        return composition
    }

    // MARK: - Passport

    /// The open pages of a made-up passport, a specimen from a country that
    /// does not exist, with the mosaic brush already run over the holder's
    /// name, birth date, number and machine-readable lines.
    static func passport(_ words: Words) -> Composition {
        let size = size
        var random = SampleRandom(seed: 13)
        let desk = Bitmap.render(size: size) { context in
            fillGradient(context, in: CGRect(origin: .zero, size: size), stops: [
                (0, RGBAColor(red: 0.22, green: 0.24, blue: 0.27)),
                (1, RGBAColor(red: 0.12, green: 0.13, blue: 0.15)),
            ])
            context.setFillColor(RGBAColor.white.withAlpha(0.04).cgColor)
            for _ in 0..<9000 {
                let radius = 1 + random.next() * 2
                context.fillEllipse(in: CGRect(x: random.next() * size.width, y: random.next() * size.height, width: radius, height: radius))
            }
        }

        let ink = UIColor(red: 0.12, green: 0.16, blue: 0.30, alpha: 1)
        let label = UIColor(red: 0.38, green: 0.42, blue: 0.50, alpha: 1)
        let visaPage = CGRect(x: 118, y: 110, width: 1300, height: 880)
        let dataPage = CGRect(x: 118, y: 1010, width: 1300, height: 920)
        // Where the private details are, for the mosaic to cover.
        var privateLines: [CGRect] = []

        var page = Bitmap.render(size: size) { context in
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }

            // The booklet, with a shadow on the desk and a fold between pages.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: RGBAColor.black.withAlpha(0.5).cgColor)
            context.addPath(CGPath(roundedRect: visaPage.union(dataPage), cornerWidth: 36, cornerHeight: 36, transform: nil))
            context.setFillColor(RGBAColor(red: 0.95, green: 0.95, blue: 0.91).cgColor)
            context.fillPath()
            context.restoreGState()
            for (rect, tint) in [(visaPage, RGBAColor(red: 0.90, green: 0.94, blue: 0.90)), (dataPage, RGBAColor(red: 0.90, green: 0.92, blue: 0.97))] {
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil))
                context.clip()
                context.setFillColor(tint.cgColor)
                context.fill(rect)
                // Guilloche: fine interlaced waves across the page.
                context.setLineWidth(1.4)
                for line in 0..<46 {
                    let phase = Double(line) * 0.42
                    let path = CGMutablePath()
                    for step in 0...130 {
                        let x = rect.minX + rect.width * Double(step) / 130
                        let y = rect.minY + Double(line) * rect.height / 44 + sin(Double(step) * 0.16 + phase) * 22
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.addPath(path)
                    context.setStrokeColor(RGBAColor(red: 0.45, green: 0.55, blue: 0.75, alpha: 0.13).cgColor)
                    context.strokePath()
                }
                context.restoreGState()
            }
            fillGradient(context, in: CGRect(x: visaPage.minX, y: 975, width: visaPage.width, height: 50), stops: [
                (0, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)),
                (0.5, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.18)),
                (1, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)),
            ])

            func draw(_ text: String, at point: CGPoint, size: Double, weight: UIFont.Weight = .regular, color: UIColor = ink, mono: Bool = false, spacing: Double = 0) -> CGRect {
                let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: spacing]
                (text as NSString).draw(at: point, withAttributes: attributes)
                return CGRect(origin: point, size: (text as NSString).size(withAttributes: attributes))
            }

            // Visa stamps on the upper page, each at its own angle.
            _ = draw("VISAS", at: CGPoint(x: visaPage.minX + 60, y: visaPage.minY + 40), size: 34, weight: .semibold, color: label, spacing: 8)
            let stamps: [(CGPoint, Double, RGBAColor, String, String)] = [
                (CGPoint(x: 420, y: 420), -0.18, RGBAColor(red: 0.75, green: 0.15, blue: 0.20), "ARRIVED", "12 JUL 2026"),
                (CGPoint(x: 1050, y: 380), 0.12, RGBAColor(red: 0.20, green: 0.30, blue: 0.70), "DEPARTED", "03 AUG 2026"),
                (CGPoint(x: 760, y: 740), -0.06, RGBAColor(red: 0.45, green: 0.25, blue: 0.60), "ENTRY", "21 SEP 2026"),
            ]
            for (index, (center, angle, color, title, date)) in stamps.enumerated() {
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: angle)
                context.setStrokeColor(color.withAlpha(0.75).cgColor)
                context.setLineWidth(7)
                let box = CGRect(x: -190, y: -110, width: 380, height: 220)
                if index == 1 {
                    context.strokeEllipse(in: box.insetBy(dx: 30, dy: -20))
                } else {
                    context.addPath(CGPath(roundedRect: box, cornerWidth: 24, cornerHeight: 24, transform: nil))
                    context.strokePath()
                }
                let stampColor = UIColor(cgColor: color.withAlpha(0.8).cgColor)
                let titleRect = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 54, weight: .heavy), .kern: 4])
                _ = draw(title, at: CGPoint(x: -titleRect.width / 2, y: -70), size: 54, weight: .heavy, color: stampColor, spacing: 4)
                let dateRect = (date as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 40, weight: .bold)])
                _ = draw(date, at: CGPoint(x: -dateRect.width / 2, y: 10), size: 40, weight: .bold, color: stampColor, mono: true)
                context.restoreGState()
            }

            // The data page.
            _ = draw("PASSPORT", at: CGPoint(x: dataPage.minX + 60, y: dataPage.minY + 40), size: 40, weight: .heavy, color: ink, spacing: 6)
            _ = draw("REPUBLIC OF EASELIA", at: CGPoint(x: dataPage.minX + 470, y: dataPage.minY + 44), size: 36, weight: .semibold, color: label, spacing: 4)

            let photo = CGRect(x: dataPage.minX + 60, y: dataPage.minY + 130, width: 330, height: 420)
            context.saveGState()
            context.addPath(CGPath(roundedRect: photo, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.clip()
            fillGradient(context, in: photo, stops: [
                (0, RGBAColor(red: 0.80, green: 0.86, blue: 0.94)), (1, RGBAColor(red: 0.62, green: 0.72, blue: 0.86)),
            ])
            let skin = RGBAColor(red: 0.93, green: 0.76, blue: 0.64).cgColor
            let hair = RGBAColor(red: 0.30, green: 0.20, blue: 0.16).cgColor
            context.setFillColor(RGBAColor(red: 0.20, green: 0.36, blue: 0.55).cgColor)
            context.fillEllipse(in: CGRect(x: photo.midX - 170, y: photo.maxY - 140, width: 340, height: 300))
            context.setFillColor(skin)
            context.fill(CGRect(x: photo.midX - 36, y: photo.minY + 250, width: 72, height: 60))
            context.setFillColor(hair)
            context.fillEllipse(in: CGRect(x: photo.midX - 112, y: photo.minY + 58, width: 224, height: 250))
            context.setFillColor(skin)
            context.fillEllipse(in: CGRect(x: photo.midX - 90, y: photo.minY + 100, width: 180, height: 210))
            context.setFillColor(hair)
            context.fillEllipse(in: CGRect(x: photo.midX - 100, y: photo.minY + 66, width: 200, height: 90))
            context.setFillColor(RGBAColor(red: 0.20, green: 0.15, blue: 0.15).cgColor)
            context.fillEllipse(in: CGRect(x: photo.midX - 45, y: photo.minY + 190, width: 16, height: 16))
            context.fillEllipse(in: CGRect(x: photo.midX + 29, y: photo.minY + 190, width: 16, height: 16))
            context.setStrokeColor(RGBAColor(red: 0.70, green: 0.35, blue: 0.35).cgColor)
            context.setLineWidth(5)
            context.addArc(center: CGPoint(x: photo.midX, y: photo.minY + 236), radius: 28, startAngle: 0.5, endAngle: .pi - 0.5, clockwise: false)
            context.strokePath()
            context.restoreGState()

            let column = dataPage.minX + 450
            let fields: [(label: String, value: String, x: Double, y: Double, isPrivate: Bool)] = [
                ("Type", "P", column, 140, false),
                ("Code", "EAS", column + 150, 140, false),
                ("Passport No.", "E 4815 1623", column + 340, 140, true),
                ("Surname", "SAMPLE", column, 245, true),
                ("Given names", "ALEX JORDAN", column, 350, true),
                ("Nationality", "EASELIAN", column, 455, false),
                ("Date of birth", "14 MAR 1994", column, 560, true),
                ("Sex", "X", column + 340, 560, false),
                ("Date of expiry", "08 OCT 2036", column + 460, 560, false),
            ]
            for field in fields {
                _ = draw(field.label, at: CGPoint(x: field.x, y: dataPage.minY + field.y), size: 26, weight: .medium, color: label)
                let value = draw(field.value, at: CGPoint(x: field.x, y: dataPage.minY + field.y + 34), size: 46, weight: .bold, mono: field.value.contains(where: \.isNumber))
                if field.isPrivate { privateLines.append(value) }
            }

            let mrzTop = dataPage.minY + 690
            for (index, line) in ["P<EASSAMPLE<<ALEX<JORDAN<<<<<<<<<<<<<<<<<<<", "E48151623<6EAS9403146X3610083<<<<<<<<<<<<04"].enumerated() {
                privateLines.append(draw(line, at: CGPoint(x: dataPage.minX + 60, y: mrzTop + Double(index) * 76), size: 44, weight: .medium, mono: true, spacing: 0.5))
            }

            // Specimen, printed across the page so nobody takes it for real.
            context.saveGState()
            context.translateBy(x: dataPage.midX + 260, y: dataPage.minY + 330)
            context.rotate(by: -0.28)
            let specimen = "SPECIMEN"
            let specimenFont = UIFont.systemFont(ofSize: 120, weight: .black)
            let specimenSize = (specimen as NSString).size(withAttributes: [.font: specimenFont, .kern: 20])
            (specimen as NSString).draw(at: CGPoint(x: -specimenSize.width / 2, y: -specimenSize.height / 2), withAttributes: [
                .font: specimenFont, .kern: 20, .foregroundColor: UIColor(red: 0.85, green: 0.20, blue: 0.25, alpha: 0.18),
            ])
            context.restoreGState()
        }

        // The mosaic brush, run along each private line.
        let settings = BrushSettings(size: 70, opacity: 0.6, usesPressure: false, usesTilt: false)
        let mosaic = RetouchEffect.image(.mosaic, settings: settings, of: page)
        for line in privateLines {
            let y = line.midY
            let stroke = Stroke(
                points: densified([CGPoint(x: line.minX + 10, y: y), CGPoint(x: line.maxX - 10, y: y)]).map { StrokePoint(location: $0) },
                settings: settings, kind: .mosaic
            )
            page = Painter.apply(mosaic, onto: page, through: stroke)
        }

        return Composition(size: size, layers: [
            layer(words.t("Desk", "机"), desk),
            layer(words.t("Passport", "パスポート"), page),
        ])
    }

    // MARK: - Painting

    private static func layer(_ name: String, _ image: CGImage, group: LayerGroup? = nil) -> Layer {
        var layer = Layer(name: name, image: LayerImage(image), canvasSize: size)
        layer.groupID = group?.id
        return layer
    }

    private static func brush(
        size: Double, color: RGBAColor, opacity: Double = 1, softness: Double = 0, tip: BrushTip
    ) -> BrushSettings {
        BrushSettings(size: size, opacity: opacity, softness: softness, color: color, usesTilt: false, tip: tip)
    }

    /// One stroke of the app's own brush through `points`, densified so its
    /// curve is smooth. Tapered strokes press in and lift off as a hand does.
    private static func paint(
        _ context: CGContext, _ points: [CGPoint], _ settings: BrushSettings, taper: Bool = false,
        canvasSize: CGSize = AppStoreSamples.size
    ) {
        let path = densified(points)
        var settings = settings
        settings.usesPressure = taper
        let stroke = Stroke(
            points: path.enumerated().map { index, point in
                let t = Double(index) / Double(max(1, path.count - 1))
                return StrokePoint(location: point, pressure: taper ? max(0.05, sin(.pi * min(1, t * 1.15 + 0.08))) : 1)
            },
            settings: settings, kind: .paint
        )
        // Clipped to where the stroke can reach, so its transparency layer
        // is only that big rather than the whole canvas.
        context.saveGState()
        context.clip(to: stroke.bounds)
        stroke.paint(in: context, canvasSize: canvasSize)
        context.restoreGState()
    }

    /// Catmull-Rom points between the given ones, every few pixels.
    private static func densified(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result: [CGPoint] = []
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)], p1 = points[index]
            let p2 = points[index + 1], p3 = points[min(points.count - 1, index + 2)]
            let length = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = max(2, Int(length / 6))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let t2 = t * t, t3 = t2 * t
                func blend(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                result.append(CGPoint(x: blend(p0.x, p1.x, p2.x, p3.x), y: blend(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    private static func wave(from start: CGPoint, length: Double, amplitude: Double, random: inout SampleRandom) -> [CGPoint] {
        (0...6).map { index in
            CGPoint(x: start.x + length * Double(index) / 6, y: start.y + (random.next() - 0.5) * 2 * amplitude)
        }
    }

    private static func arc(
        center: CGPoint, radius: Double, from start: Double, to end: Double, wobble: Double, random: inout SampleRandom
    ) -> [CGPoint] {
        (0...8).map { index in
            let angle = start + (end - start) * Double(index) / 8
            let r = radius + (random.next() - 0.5) * 2 * wobble
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
    }

    /// A mountain skyline from the left edge to the right, closed along `base`.
    private static func ridge(base: Double, height: Double, roughness: Double, seed: UInt64, width: Double) -> CGPath {
        var random = SampleRandom(seed: seed)
        var heights = [Double](repeating: 0, count: 65)
        // Midpoint displacement: big swings first, smaller ones between them.
        heights[0] = random.next() * 0.6
        heights[64] = random.next() * 0.6
        var step = 64
        var spread = 1.0
        while step > 1 {
            let half = step / 2
            for index in stride(from: half, to: 64, by: step) {
                heights[index] = (heights[index - half] + heights[index + half]) / 2 + (random.next() - 0.5) * spread
            }
            step = half
            spread *= roughness
        }
        let low = heights.min() ?? 0, high = heights.max() ?? 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: base + 4))
        for (index, value) in heights.enumerated() {
            let normalized = (value - low) / max(0.0001, high - low)
            path.addLine(to: CGPoint(x: width * Double(index) / 64, y: base - 20 - normalized * height))
        }
        path.addLine(to: CGPoint(x: width, y: base + 4))
        path.closeSubpath()
        return path
    }

    /// The top of a closed skyline at `x`.
    private static func highest(_ path: CGPath, at x: Double) -> Double {
        var y = 0.0
        while y < 4000, !path.contains(CGPoint(x: x, y: y)) { y += 4 }
        return y
    }

    private static func fillGradient(_ context: CGContext, in rect: CGRect, stops: [(Double, RGBAColor)]) {
        let colors = stops.map(\.1.cgColor) as CFArray
        let locations = stops.map { CGFloat($0.0) }
        guard let gradient = CGGradient(colorsSpace: Bitmap.colorSpace, colors: colors, locations: locations) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}

private extension RGBAColor {
    func mixed(with other: RGBAColor, by amount: Double) -> RGBAColor {
        RGBAColor(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount, alpha: alpha
        )
    }
}

/// A small seeded random source, so the samples come out the same each run.
private struct SampleRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    /// The next number, from 0 up to 1.
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 100_000) / 100_000
    }
}
