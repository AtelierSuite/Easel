import Paintbrush
import SwiftUI

/// The brush in hand at the size it paints, in glass over the middle of the
/// canvas, with its size beneath, while its size is being set.
struct BrushSizePreview: View {
    let brush: BrushSettings
    let tool: Tool
    /// Points per canvas pixel.
    let scale: Double

    var body: some View {
        let diameter = max(brush.size * scale, 2)
        ZStack {
            Circle()
                .fill(dab)
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular, in: Circle())
                .overlay {
                    // Light and dark, so the edge shows on any picture.
                    Circle().stroke(.black.opacity(0.5), lineWidth: 2.5)
                    Circle().stroke(.white, lineWidth: 1)
                }

            Text(verbatim: "\(Int(brush.size.rounded())) px")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                // Below the dab while it is small enough to leave room; in
                // it, not off screen, once it is large.
                .offset(y: min(diameter / 2 + 28, 140))
        }
        .accessibilityHidden(true)
    }

    /// The mark the brush leaves: its colour for the brush, a neutral one
    /// for the tools that do not lay paint down, feathered by its softness.
    private var dab: some ShapeStyle {
        let color: Color = tool == .brush
            ? Color(red: brush.color.red, green: brush.color.green, blue: brush.color.blue)
                .opacity(brush.color.alpha * brush.opacity)
            : .white.opacity(0.35 * max(brush.opacity, 0.3))
        let hardness = 1 - min(max(brush.softness, 0), 1)
        return RadialGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color, location: hardness * 0.5),
                .init(color: color.opacity(0), location: 0.5),
            ],
            center: .center, startRadius: 0, endRadius: max(brush.size * scale, 2)
        )
    }
}
