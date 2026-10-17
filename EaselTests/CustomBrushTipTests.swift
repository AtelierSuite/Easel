import CoreGraphics
import Foundation
import Testing
@testable import Easel
@testable import Paintbrush

@Suite("Imported brush tips", .serialized)
struct CustomBrushTipTests {
    /// A black ring on white, as a scan of a mark on paper would be.
    private var scannedRing: CGImage {
        Bitmap.render(size: CGSize(width: 200, height: 100)) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(10)
            context.strokeEllipse(in: CGRect(x: 60, y: 10, width: 80, height: 80))
        }
    }

    @Test func aScanPaintsWhereItIsDark() {
        let tip = CustomBrushTips.shape(of: scannedRing)
        #expect(tip.width == 128 && tip.height == 128)
        // The ring paints; the white paper inside and around it does not.
        #expect(TestImages.pixel(tip, x: 64, y: 64).alpha < 10)
        #expect(TestImages.pixel(tip, x: 64, y: 64 - 26).alpha > 200)
        #expect(TestImages.pixel(tip, x: 5, y: 5).alpha < 10)
    }

    @Test func aCutOutPaintsWhereItIsSolid() {
        // A white square on clear: dark or light, it is the shape that counts.
        let cutOut = Bitmap.render(size: CGSize(width: 50, height: 50)) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
        }
        let tip = CustomBrushTips.shape(of: cutOut)
        #expect(TestImages.pixel(tip, x: 64, y: 64).alpha > 250)
        #expect(TestImages.pixel(tip, x: 10, y: 10).alpha == 0)
    }

    @Test @MainActor func anImportedTipIsKeptPaintedWithAndDeleted() throws {
        let library = CustomBrushTipLibrary()
        let id = try library.add(scannedRing)
        defer { library.delete(id) }
        #expect(CustomBrushTipLibrary().tips.contains(id))
        var settings = BrushSettings(size: 30, usesPressure: false)
        settings.tip = .custom
        settings.customTip = id
        // A single dab: the ring, its middle left bare.
        let dab = Stroke(points: [StrokePoint(location: CGPoint(x: 50, y: 50))], settings: settings, kind: .paint)
        let image = Painter.paint(dab, onto: Bitmap.render(size: CGSize(width: 100, height: 100)) { _ in })
        #expect(TestImages.pixel(image, x: 50, y: 50).alpha < 30)
        #expect(TestImages.pixel(image, x: 50, y: 50 - 6).alpha > 150)
        // Saved as a brush, it keeps its picture.
        #expect(BrushPreset(name: "Ring", settings: settings).applied(to: BrushSettings(size: 1)).customTip == id)
        library.delete(id)
        #expect(!library.tips.contains(id))
        // Once deleted, a brush still using it stamps a round tip.
        let after = Painter.paint(dab, onto: Bitmap.render(size: CGSize(width: 100, height: 100)) { _ in })
        #expect(TestImages.pixel(after, x: 50, y: 50).alpha > 200)
    }
}
