import CoreGraphics
import Testing
@testable import Easel

@Suite("Retouching")
struct RetouchTests {
    private func line(_ kind: Stroke.Kind, size: Double = 6, from: CGPoint, to: CGPoint, strength: Double = 1) -> Stroke {
        Stroke(
            points: [StrokePoint(location: from), StrokePoint(location: to)],
            settings: BrushSettings(size: size, opacity: strength, usesPressure: false), kind: kind
        )
    }

    /// Red on the left, blue on the right, 40 by 20.
    private var halves: CGImage { TestImages.halves(width: 40, height: 20) }

    @Test func blurBrushSoftensOnlyWhereItGoes() {
        let stroke = line(.blur, size: 8, from: CGPoint(x: 20, y: 2), to: CGPoint(x: 20, y: 18))
        let effect = RetouchEffect.image(.blur, settings: stroke.settings, of: halves)
        let result = Painter.apply(effect, onto: halves, through: stroke)
        // At the seam, red and blue mix.
        let seam = TestImages.pixel(result, x: 20, y: 10)
        #expect(seam.red > 40 && seam.blue > 40)
        // Away from the stroke, untouched.
        #expect(TestImages.isRed(result, x: 2, y: 10))
        #expect(TestImages.isBlue(result, x: 38, y: 10))
    }

    @Test func motionBlurRespectsDirectionAndStrokeBounds() {
        let stroke = line(.motionBlur(angle: 0), size: 16,
                          from: CGPoint(x: 20, y: 2), to: CGPoint(x: 20, y: 18))
        let horizontal = RetouchEffect.image(stroke.kind, settings: stroke.settings, of: halves)
        let vertical = RetouchEffect.image(.motionBlur(angle: 90), settings: stroke.settings, of: halves)
        let seam = TestImages.pixel(horizontal, x: 20, y: 10)
        #expect(seam.red > 40 && seam.blue > 40)
        #expect(TestImages.isBlue(vertical, x: 20, y: 10))
        let result = Painter.apply(horizontal, onto: halves, through: stroke)
        #expect(TestImages.isRed(result, x: 2, y: 10))
        #expect(TestImages.isBlue(result, x: 38, y: 10))
        #expect(stroke.asMask.settings.opacity == 1)
    }

    @MainActor
    @Test func censorTypesShareSettingsAndCaptureMotionDirection() {
        let state = EditorState()
        state.tool = .censor
        state.currentBrush.size = 18
        state.censorKind = .mosaic
        #expect(state.strokeKind == .mosaic)
        #expect(state.currentBrush.size == 18)
        state.censorKind = .motionBlur
        state.censorAngle = 45
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(halves)
        state.attach(to: composition) { _ in }
        state.toolBegan(at: CGPoint(x: 20, y: 4), pressure: 1)
        #expect(state.activeStroke?.kind == .motionBlur(angle: 45))
        state.censorAngle = 90
        #expect(state.activeStroke?.kind == .motionBlur(angle: 45))
        state.censorKind = .smudge
        #expect(state.activeStroke == nil)
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 30, y: 10))])
        #expect(state.smudge?.patches.isEmpty == false)
        state.censorKind = .gaussianBlur
        #expect(state.smudge == nil)
    }

    @Test func cloneCopiesFromTheOffsetThroughTheStroke() {
        // Paint the right (blue) half with what is 20 pixels to its left.
        let offset = CGVector(dx: -20, dy: 0)
        let stroke = line(.clone(offset: offset), size: 6, from: CGPoint(x: 30, y: 4), to: CGPoint(x: 30, y: 16))
        let effect = RetouchEffect.image(stroke.kind, settings: stroke.settings, of: halves)
        let result = Painter.apply(effect, onto: halves, through: stroke)
        #expect(TestImages.isRed(result, x: 30, y: 10))
        #expect(TestImages.isBlue(result, x: 37, y: 10))
        #expect(TestImages.isRed(result, x: 10, y: 10))
    }

    @Test func cloneOpacityMixesTheCopyIn() {
        let stroke = line(.clone(offset: CGVector(dx: -20, dy: 0)), size: 6, from: CGPoint(x: 30, y: 4), to: CGPoint(x: 30, y: 16), strength: 0.5)
        let effect = RetouchEffect.image(stroke.kind, settings: stroke.settings, of: halves)
        let pixel = TestImages.pixel(Painter.apply(effect, onto: halves, through: stroke), x: 30, y: 10)
        #expect(pixel.red > 80 && pixel.red < 180)
        #expect(pixel.blue > 80 && pixel.blue < 180)
    }

    @Test func fillingASelectionFromItsSurroundingsHidesWhatWasThere() {
        let size = CGSize(width: 60, height: 60)
        let image = Bitmap.render(size: size) { context in
            context.setFillColor(RGBAColor(red: 0, green: 0, blue: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 20, y: 20, width: 20, height: 20))
        }
        let selection = Selection(shape: .rectangle(CGRect(x: 18, y: 18, width: 24, height: 24)))
        let filled = Healer.fill(image, selection: selection)
        #expect(TestImages.isBlue(filled, x: 30, y: 30))
        #expect(TestImages.isBlue(filled, x: 21, y: 21))
        #expect(TestImages.isBlue(filled, x: 5, y: 5))
    }

    @Test func fillingFollowsAGradientAcrossTheHole() {
        let size = CGSize(width: 80, height: 40)
        let image = Bitmap.render(size: size) { context in
            for x in 0..<80 {
                let value = Double(x) / 79
                context.setFillColor(RGBAColor(red: value, green: value, blue: value).cgColor)
                context.fill(CGRect(x: x, y: 0, width: 1, height: 40))
            }
            context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
            context.fill(CGRect(x: 30, y: 12, width: 20, height: 16))
        }
        let selection = Selection(shape: .ellipse(CGRect(x: 26, y: 8, width: 28, height: 24)))
        let filled = Healer.fill(image, selection: selection)
        let center = TestImages.pixel(filled, x: 40, y: 20)
        // Grey near the middle of the ramp, the red gone.
        #expect(abs(center.red - center.green) < 25)
        #expect(center.green > 70 && center.green < 190)
        // Darker on the left of the hole than on the right.
        #expect(TestImages.pixel(filled, x: 32, y: 20).green < TestImages.pixel(filled, x: 48, y: 20).green)
    }

    @Test func liquifyPushesThePictureAlongTheDrag() throws {
        // Red left of x = 20, blue right of it.
        let pixels = try #require(Bitmap.pixels(of: TestImages.halves(width: 40, height: 20)))
        let settings = BrushSettings(size: 16, opacity: 1, softness: 0.5, usesPressure: false)
        var liquifier = Liquifier(pixels: pixels, settings: settings, selection: nil, start: CGPoint(x: 18, y: 10))
        _ = liquifier.drag(to: CGPoint(x: 24, y: 10))
        let pushed = try #require(liquifier.pixels.makeImage())
        // Red has been pushed past the old edge, where the brush was.
        #expect(TestImages.isRed(pushed, x: 21, y: 10))
        // Out of the brush's reach, nothing moved.
        #expect(TestImages.isBlue(pushed, x: 21, y: 1))
        #expect(TestImages.isRed(pushed, x: 2, y: 10))
    }

    @Test func liquifyingBackAndForthKeepsThePictureSharp() throws {
        let pixels = try #require(Bitmap.pixels(of: TestImages.halves(width: 40, height: 20)))
        let settings = BrushSettings(size: 16, opacity: 1, softness: 0.5, usesPressure: false)
        var liquifier = Liquifier(pixels: pixels, settings: settings, selection: nil, start: CGPoint(x: 18, y: 10))
        for _ in 0..<5 {
            _ = liquifier.drag(to: CGPoint(x: 24, y: 10))
            _ = liquifier.drag(to: CGPoint(x: 18, y: 10))
        }
        let image = try #require(liquifier.pixels.makeImage())
        // Still plainly red or blue, but for the one pixel the edge may
        // fall within; pushing the pixels themselves each time would have
        // smeared a wide band.
        let muddy = (0..<40).filter { x in
            let pixel = TestImages.pixel(image, x: x, y: 10)
            return pixel.red <= 200 && pixel.blue <= 200
        }
        #expect(muddy.count <= 1)
    }

    @Test func mosaicBrushMakesTilesOnTheCanvasGrid() {
        let source = Bitmap.render(size: CGSize(width: 40, height: 40)) { context in
            for x in 0..<40 {
                context.setFillColor(RGBAColor(red: Double(x) / 40, green: 0, blue: 0).cgColor)
                context.fill(CGRect(x: x, y: 0, width: 1, height: 40))
            }
        }
        var settings = BrushSettings(size: 40, opacity: 0.5, usesPressure: false)
        settings.softness = 0
        let cell = Int(RetouchEffect.mosaicCell(for: settings))
        let effect = RetouchEffect.image(.mosaic, settings: settings, of: source)
        // Within one tile, every pixel is the same.
        #expect(TestImages.pixel(effect, x: 0, y: 0) == TestImages.pixel(effect, x: cell - 1, y: cell - 1))
        #expect(TestImages.pixel(effect, x: 0, y: 0) != TestImages.pixel(effect, x: cell, y: 0))
    }

    @Test func mosaicTilesAverageWhatTheyCover() {
        // A thin dark line, like a stroke of text, off the middle of a tile.
        let source = Bitmap.render(size: CGSize(width: 40, height: 40)) { context in
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(RGBAColor.black.cgColor)
            context.fill(CGRect(x: 2, y: 0, width: 2, height: 40))
        }
        let settings = BrushSettings(size: 40, opacity: 0.5, usesPressure: false)
        let effect = RetouchEffect.image(.mosaic, settings: settings, of: source)
        // The tile is neither left white nor turned black, but grey.
        let pixel = TestImages.pixel(effect, x: 6, y: 6)
        #expect(pixel.red > 120 && pixel.red < 240)
    }

    @Test func smudgeDragsColourAlong() {
        let pixels = Bitmap.pixels(of: halves)!
        var smudger = Smudger(
            pixels: pixels, settings: BrushSettings(size: 8, opacity: 0.9, usesPressure: false),
            selection: nil, start: CGPoint(x: 10, y: 10)
        )
        let changed = smudger.drag(to: CGPoint(x: 30, y: 10))
        #expect(changed != nil)
        let image = smudger.pixels.makeImage()!
        // Red has been carried into the blue half.
        #expect(TestImages.pixel(image, x: 25, y: 10).red > 60)
        // Outside the brush's path, nothing moved.
        #expect(TestImages.isBlue(image, x: 30, y: 1))
    }

    @Test func smudgeStaysInsideTheSelection() {
        let pixels = Bitmap.pixels(of: halves)!
        var smudger = Smudger(
            pixels: pixels, settings: BrushSettings(size: 8, opacity: 0.9, usesPressure: false),
            selection: Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 24, height: 20))), start: CGPoint(x: 10, y: 10)
        )
        _ = smudger.drag(to: CGPoint(x: 34, y: 10))
        #expect(TestImages.isBlue(smudger.pixels.makeImage()!, x: 30, y: 10))
    }

    @Test func healCoversASpotWithItsSurroundings() {
        // A grey field with a black blemish in the middle.
        let image = Bitmap.render(size: CGSize(width: 80, height: 80)) { context in
            context.setFillColor(RGBAColor(red: 0.6, green: 0.6, blue: 0.6).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            context.setFillColor(RGBAColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: 36, y: 36, width: 8, height: 8))
        }
        let before = TestImages.pixel(image, x: 40, y: 40)
        #expect(before.red < 20)
        let stroke = line(.heal, size: 16, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 40, y: 40))
        let healed = Healer.heal(image, with: stroke)
        let after = TestImages.pixel(healed, x: 40, y: 40)
        let field = TestImages.pixel(image, x: 10, y: 10)
        #expect(abs(after.red - field.red) < 25)
        // Far from the spot, unchanged.
        #expect(TestImages.pixel(healed, x: 5, y: 5) == field)
    }

    @Test func boxBlurKeepsTheAverage() {
        var values: [Float] = [0, 0, 0, 9, 0, 0, 0]
        Healer.boxBlur(&values, width: 7, height: 1, radius: 1, passes: 1)
        #expect(abs(values.reduce(0, +) - 9) < 0.01)
        #expect(values[3] == 3)
    }
}

@MainActor
@Suite("Retouch tools")
struct RetouchToolTests {
    @Test func smudgingChangesTheLayerAndKeepsFilters() throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        var published = composition
        state.attach(to: published) { published = $0 }
        state.addFilter(.sepia)
        state.tool = .censor
        state.censorKind = .smudge
        state.toolBegan(at: CGPoint(x: 10, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 30, y: 10))])
        #expect(state.smudge?.patches.isEmpty == false)
        state.toolEnded(isTap: false, at: CGPoint(x: 30, y: 10))
        #expect(state.smudge == nil)
        #expect(published.layers[0].filters.count == 1)
        #expect(TestImages.pixel(published.layers[0].image.cgImage, x: 25, y: 10).red > 60)
    }

    @Test func cloneStampPicksASourceThenKeepsItsOffset() async throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        var published = composition
        state.attach(to: published) { published = $0 }
        state.tool = .clone
        state.cloneBrush.size = 4
        state.cloneBrush.softness = 0

        // The first tap only picks the source.
        state.toolBegan(at: CGPoint(x: 5, y: 5), pressure: 1)
        state.toolEnded(isTap: true, at: CGPoint(x: 5, y: 5))
        #expect(state.cloneSource == CGPoint(x: 5, y: 5))
        #expect(state.activeStroke == nil)

        // A stroke starting at (25, 5) copies from 20 to its left.
        state.toolBegan(at: CGPoint(x: 25, y: 5), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 25, y: 8))])
        state.toolEnded(isTap: false, at: CGPoint(x: 25, y: 8))
        #expect(state.cloneOffset == CGVector(dx: -20, dy: 0))
        #expect(state.cloneSource == CGPoint(x: 5, y: 8))

        // A later stroke elsewhere keeps the same offset.
        state.toolBegan(at: CGPoint(x: 32, y: 14), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 32, y: 16))])
        state.toolEnded(isTap: false, at: CGPoint(x: 32, y: 16))
        for _ in 0..<100 where state.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        let image = published.layers[0].image.cgImage
        #expect(TestImages.isRed(image, x: 25, y: 6))
        #expect(TestImages.isRed(image, x: 32, y: 15))
        #expect(TestImages.isBlue(image, x: 37, y: 2))

        // Picking again starts a new offset.
        state.isPickingCloneSource = true
        state.toolBegan(at: CGPoint(x: 1, y: 1), pressure: 1)
        #expect(state.activeStroke == nil)
        state.toolEnded(isTap: true, at: CGPoint(x: 1, y: 1))
        #expect(state.cloneOffset == nil)
        #expect(!state.isPickingCloneSource)
    }

    @Test func liquifyChangesTheLayerWhenTheFingerLifts() throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        var published = composition
        state.attach(to: published) { published = $0 }
        state.tool = .liquify
        state.liquifyBrush.size = 16
        state.toolBegan(at: CGPoint(x: 16, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 26, y: 10))])
        #expect(state.smudge?.patches.isEmpty == false)
        state.toolEnded(isTap: false, at: CGPoint(x: 26, y: 10))
        #expect(state.smudge == nil)
        #expect(TestImages.isRed(published.layers[0].image.cgImage, x: 22, y: 10))
    }

    @Test func liquifyingASmartObjectGoesIntoItsLiquifyFilter() throws {
        let state = EditorState()
        var composition = Composition.blank(size: CGSize(width: 40, height: 20))
        composition.layers[0].image = LayerImage(TestImages.halves(width: 40, height: 20))
        let converted = composition.convertToSmartObject([composition.layers[0].id])
        let id = try #require(converted)
        var published = composition
        state.attach(to: published) { published = $0 }
        state.activeLayerID = id
        state.tool = .liquify
        state.liquifyBrush.size = 16
        state.toolBegan(at: CGPoint(x: 16, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 26, y: 10))])
        state.toolEnded(isTap: false, at: CGPoint(x: 26, y: 10))
        let layer = try #require(published[id])
        #expect(layer.isSmartObject)
        #expect(layer.filters.map(\.kind) == [.liquify])
        // Red pushed into the right half, as the brush on pixels would.
        #expect(TestImages.isRed(layer.renderedImage, x: 22, y: 10))
        // Another drag adds to the same filter.
        state.toolBegan(at: CGPoint(x: 30, y: 10), pressure: 1)
        state.toolMoved(to: [StrokePoint(location: CGPoint(x: 34, y: 10))])
        state.toolEnded(isTap: false, at: CGPoint(x: 34, y: 10))
        #expect(published[id]?.filters.count == 1)
    }

    @Test func retouchToolsKeepTheirOwnSettings() {
        let state = EditorState()
        state.tool = .censor
        state.currentBrush.size = 123
        state.tool = .brush
        #expect(state.currentBrush.size != 123)
        state.tool = .censor
        #expect(state.currentBrush.size == 123)
        #expect(state.strokeKind == .blur)
    }
}
