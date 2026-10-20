import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Image automation")
struct ImageAutomationTests {
    private var photo: CGImage { TestImages.halves(width: 40, height: 20) }

    @Test func oneSideGivenKeepsTheProportions() throws {
        let wide = try ImageAutomation.resize(photo, width: 20, height: nil)
        #expect((wide.width, wide.height) == (20, 10))
        let tall = try ImageAutomation.resize(photo, width: nil, height: 40)
        #expect((tall.width, tall.height) == (80, 40))
    }

    @Test func bothSidesFitOrStretch() throws {
        let fitted = try ImageAutomation.resize(photo, width: 30, height: 30)
        #expect((fitted.width, fitted.height) == (30, 15))
        let stretched = try ImageAutomation.resize(photo, width: 30, height: 30, keepsProportions: false)
        #expect((stretched.width, stretched.height) == (30, 30))
        #expect(TestImages.isRed(stretched, x: 2, y: 15))
        #expect(TestImages.isBlue(stretched, x: 28, y: 15))
    }

    @Test func noSizeIsAnError() {
        #expect(throws: ImageAutomation.Failure.noSize) { try ImageAutomation.resize(photo, width: nil, height: nil) }
    }

    @Test func convertedFilesReadBackInEveryFormat() throws {
        for format in [CompositionExport.Format.png, .jpeg, .heic, .psd] {
            let data = try ImageAutomation.data(for: photo, as: format)
            let name = ImageAutomation.filename("Holiday.png", as: format)
            #expect(name == "Holiday." + format.pathExtension)
            let read = try ImageAutomation.image(from: data, filename: name)
            #expect((read.width, read.height) == (40, 20), "\(format)")
            #expect(TestImages.isRed(read, x: 5, y: 10), "\(format)")
        }
    }

    @Test func keepingASelectionClearsTheRest() {
        let kept = ImageAutomation.keeping(Selection(shape: .rectangle(CGRect(x: 0, y: 0, width: 20, height: 20))), of: photo)
        #expect(TestImages.isRed(kept, x: 5, y: 10))
        #expect(TestImages.isClear(kept, x: 30, y: 10))
    }

    @Test func aFileWithoutANameStillGetsOne() {
        #expect(ImageAutomation.filename("", as: .jpeg) == String(localized: "Intent.DefaultName") + ".jpg")
    }
}
