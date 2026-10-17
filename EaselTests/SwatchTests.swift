import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@MainActor
@Suite("Swatches")
struct SwatchTests {
    private func host() -> (EditorState, () -> Composition) {
        let state = EditorState()
        let composition = Composition.blank(size: CGSize(width: 10, height: 10))
        nonisolated(unsafe) var published = composition
        state.attach(to: composition) { published = $0 }
        return (state, { published })
    }

    @Test func aColourIsKeptOnceAndOpaque() {
        let (state, published) = host()
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        state.addSwatch(red)
        state.addSwatch(red.withAlpha(0.5))
        state.addSwatch(.white)
        #expect(published().swatches == [red, .white])
        state.removeSwatch(at: 0)
        #expect(published().swatches == [.white])
        state.removeSwatch(at: 5)
        #expect(published().swatches == [.white])
    }

    @Test func swatchesAreSavedWithThePicture() throws {
        var composition = Composition.blank(size: CGSize(width: 10, height: 10))
        composition.swatches = [RGBAColor(red: 0.2, green: 0.4, blue: 0.6), .black]
        let read = try CompositionArchive.composition(from: CompositionArchive.fileWrapper(for: composition))
        #expect(read.swatches == composition.swatches)
    }

    @Test func theSystemPaletteHasNoRepeats() {
        #expect(Set(SystemPalette.all.map(\.id)).count == SystemPalette.all.count)
        #expect(Set(SystemPalette.all.map(\.color)).count == SystemPalette.all.count)
    }
}
