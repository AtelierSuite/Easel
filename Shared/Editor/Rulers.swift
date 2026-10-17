import Paintbrush
import SwiftUI

extension EditorState {
    /// Adds a guide at `position` across the canvas.
    func addGuide(_ axis: LineAxis, at position: Double) {
        let limit = axis == .vertical ? composition.size.width : composition.size.height
        guard position >= 0, position <= limit else { return }
        update { $0.guides.append(Guide(axis: axis, position: position.rounded())) }
    }

    func clearGuides() {
        update { $0.guides.removeAll() }
    }

    /// The guide under `point`, if one is within a fingertip on screen.
    func guide(near point: CGPoint) -> Guide? {
        let reach = 12 / max(viewport.scale, 0.0001)
        return composition.guides
            .map { guide in (guide, abs((guide.axis == .vertical ? point.x : point.y) - guide.position)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    func moveGuide(_ id: Guide.ID, to point: CGPoint) {
        update { composition in
            guard let index = composition.guides.firstIndex(where: { $0.id == id }) else { return }
            let axis = composition.guides[index].axis
            composition.guides[index].position = (axis == .vertical ? point.x : point.y).rounded()
        }
    }

    /// A guide let go off the canvas is taken away, as when it is dragged
    /// back into its ruler.
    func dropGuide(_ id: Guide.ID) {
        let size = composition.size
        guard let guide = composition.guides.first(where: { $0.id == id }) else { return }
        let limit = guide.axis == .vertical ? size.width : size.height
        if guide.position < 0 || guide.position > limit {
            update { $0.guides.removeAll { $0.id == id } }
        }
    }
}

/// Scales along the top and left of the canvas, in canvas pixels. Dragging
/// out of one pulls a guide onto the canvas.
struct Rulers: View {
    @Bindable var state: EditorState
    let viewport: CanvasViewport
    static let thickness: CGFloat = 20
    static let coordinateSpace = "canvasArea"
    /// Room left under the floating title bar, which takes touches a little
    /// below its buttons.
    private static let clearance: CGFloat = 16

    private var top: CGFloat { viewport.insets.top + Self.clearance }
    private var leading: CGFloat { viewport.insets.leading }

    var body: some View {
        let insets = viewport.insets
        let width = viewport.viewportSize.width - insets.leading - insets.trailing
        let height = viewport.viewportSize.height - top - Self.thickness - insets.bottom
        ZStack(alignment: .topLeading) {
            ruler(.horizontal, start: leading, length: width)
                .frame(width: width, height: Self.thickness)
                .offset(x: leading, y: top)
                .gesture(pull(.horizontal))
            ruler(.vertical, start: top + Self.thickness, length: height)
                .frame(width: Self.thickness, height: height)
                .offset(x: leading, y: top + Self.thickness)
                .gesture(pull(.vertical))
        }
        .frame(width: viewport.viewportSize.width, height: viewport.viewportSize.height, alignment: .topLeading)
    }

    /// A ruler running along `direction`: the top one is horizontal and
    /// pulls out level guides.
    private func ruler(_ direction: LineAxis, start: CGFloat, length: CGFloat) -> some View {
        Canvas { context, size in
            let isTop = direction == .horizontal
            let transform = viewport.transform
            let scale = viewport.scale
            // Ticks about sixty points apart, on round numbers.
            let step = Self.niceStep(60 / max(scale, 0.0001))
            let minor = step / 5
            let first = isTop
                ? viewport.canvasPoint(CGPoint(x: start, y: 0)).x
                : viewport.canvasPoint(CGPoint(x: 0, y: start)).y
            let last = isTop
                ? viewport.canvasPoint(CGPoint(x: start + length, y: 0)).x
                : viewport.canvasPoint(CGPoint(x: 0, y: start + length)).y
            var ticks = Path()
            var value = (first / minor).rounded(.down) * minor
            while value <= last {
                let screen = (isTop ? CGPoint(x: value, y: 0).applying(transform).x : CGPoint(x: 0, y: value).applying(transform).y) - start
                let isMajor = abs(value / step - (value / step).rounded()) < 0.001
                let tick = Self.thickness * (isMajor ? 0.7 : 0.3)
                if isTop {
                    ticks.move(to: CGPoint(x: screen, y: Self.thickness))
                    ticks.addLine(to: CGPoint(x: screen, y: Self.thickness - tick))
                } else {
                    ticks.move(to: CGPoint(x: Self.thickness, y: screen))
                    ticks.addLine(to: CGPoint(x: Self.thickness - tick, y: screen))
                }
                if isMajor {
                    let label = Text(verbatim: "\(Int(value.rounded()))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    var place = context
                    if isTop {
                        place.translateBy(x: screen + 3, y: 2)
                    } else {
                        // Turned to read up the side, as on a desktop ruler.
                        place.translateBy(x: 2, y: screen - 3)
                        place.rotate(by: .degrees(-90))
                    }
                    place.draw(label, at: .zero, anchor: .topLeading)
                }
                value += minor
            }
            context.stroke(ticks, with: .color(.secondary), lineWidth: 0.5)
        }
        .background(.regularMaterial)
        .accessibilityHidden(true)
    }

    /// Dragging out of a ruler: a guide follows the finger and stays if it
    /// is let go over the canvas.
    private func pull(_ axis: LineAxis) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { drag in
                let point = viewport.canvasPoint(drag.location)
                state.draftGuide = Guide(axis: axis, position: axis == .horizontal ? point.y : point.x)
            }
            .onEnded { drag in
                defer { state.draftGuide = nil }
                guard let draft = state.draftGuide, viewport.canvasFrame.contains(drag.location) else { return }
                state.addGuide(draft.axis, at: draft.position)
            }
    }

    /// The round number nearest above `raw`: 1, 2 or 5 times a power of ten.
    static func niceStep(_ raw: Double) -> Double {
        let power = pow(10, (log10(max(raw, 0.0001))).rounded(.down))
        for factor in [1.0, 2, 5, 10] where factor * power >= raw {
            return factor * power
        }
        return 10 * power
    }
}
