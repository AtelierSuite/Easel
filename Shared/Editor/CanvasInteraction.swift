import Paintbrush
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One point of a stroke as the hand made it, in view coordinates.
struct StrokeSample {
    var location: CGPoint
    var pressure: Double
    /// The pen's lean and how upright it is; nil for a finger or a mouse.
    var azimuth: Double?
    var altitude: Double?
    /// When the pen was here, in seconds.
    var time: TimeInterval
}

#if os(iOS)

/// Turns touches on the canvas into tool strokes and navigation.
///
/// One finger (or Apple Pencil) works the tool in hand; two fingers pinch,
/// pan and, when `rotates`, turn the view. A second finger landing mid-stroke abandons the stroke,
/// since it was the start of a pinch. Tapping with two fingers undoes and
/// with three redoes, as in other drawing apps.
///
/// Fingers that land on the ruler move, turn and stretch it instead, and
/// leave Apple Pencil free to draw along it.
struct CanvasInteraction: UIViewRepresentable {
    var began: (StrokeSample) -> Void
    var moved: ([StrokeSample]) -> Void
    var ended: (Bool, CGPoint) -> Void
    var cancelled: () -> Void
    /// Apple Pencil or a pointer over the canvas without touching it; nil
    /// once it moves away.
    var hovered: (CGPoint?) -> Void = { _ in /* Optional. */ }
    var zoomed: (Double, CGPoint) -> Void
    var panned: (CGSize) -> Void
    /// Whether two fingers turning turn the view.
    var rotates = false
    /// How far the fingers have turned since last time, and the point
    /// between them.
    var turned: (Double, CGPoint) -> Void = { _, _ in /* Optional. */ }
    var turnEnded: () -> Void = { /* Optional. */ }
    var undo: () -> Void
    var redo: () -> Void
    /// Whether a finger at a point lands on the ruler.
    var rulerContains: (CGPoint) -> Bool = { _ in false }
    var rulerMoved: (CGSize) -> Void = { _ in /* Optional. */ }
    var rulerTurnBegan: () -> Void = { /* Optional. */ }
    /// How far the fingers have turned since they came down, and the point
    /// between them.
    var rulerTurned: (Double, CGPoint) -> Void = { _, _ in /* Optional. */ }
    var rulerResized: (Double) -> Void = { _ in /* Optional. */ }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let stroke = StrokeGestureRecognizer(target: coordinator, action: #selector(Coordinator.stroke(_:)))
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .continuous
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.rotate(_:)))
        let undo = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.undo(_:)))
        undo.numberOfTouchesRequired = 2
        let redo = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.redo(_:)))
        redo.numberOfTouchesRequired = 3
        let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(Coordinator.hover(_:)))
        for recognizer in [stroke, pinch, pan, rotation, undo, redo, hover] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }

        let rulerPan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.rulerPan(_:)))
        rulerPan.maximumNumberOfTouches = 2
        let rulerPinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.rulerPinch(_:)))
        let rulerTurn = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.rulerTurn(_:)))
        coordinator.rulerRecognizers = [rulerPan, rulerPinch, rulerTurn]
        for recognizer in coordinator.rulerRecognizers {
            // Apple Pencil draws along the ruler; only fingers move it.
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CanvasInteraction
        private var lastPinchScale: CGFloat = 1
        private var lastPanTranslation: CGPoint = .zero
        /// Where the turn was last passed on; nil until the fingers have
        /// turned far enough to mean it, so a pinch doesn't wobble the view.
        private var lastRotation: CGFloat?
        private static let rotationThreshold: CGFloat = .pi / 18
        var rulerRecognizers: [UIGestureRecognizer] = []
        private var lastRulerTranslation: CGPoint = .zero
        private var lastRulerScale: CGFloat = 1

        init(_ parent: CanvasInteraction) {
            self.parent = parent
        }

        @objc func stroke(_ recognizer: StrokeGestureRecognizer) {
            switch recognizer.state {
            case .began:
                if let first = recognizer.samples.first {
                    parent.began(first)
                    let rest = Array(recognizer.samples.dropFirst())
                    if !rest.isEmpty { parent.moved(rest) }
                }
                recognizer.samples.removeAll()
            case .changed:
                parent.moved(recognizer.samples)
                recognizer.samples.removeAll()
            case .ended:
                if !recognizer.samples.isEmpty {
                    parent.moved(recognizer.samples)
                    recognizer.samples.removeAll()
                }
                parent.ended(recognizer.isTap, recognizer.lastLocation)
            case .cancelled, .failed:
                recognizer.samples.removeAll()
                parent.cancelled()
            default:
                break
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastPinchScale = 1
            case .changed:
                let factor = recognizer.scale / lastPinchScale
                lastPinchScale = recognizer.scale
                parent.zoomed(factor, recognizer.location(in: recognizer.view))
            default:
                break
            }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastPanTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                parent.panned(CGSize(
                    width: translation.x - lastPanTranslation.x, height: translation.y - lastPanTranslation.y
                ))
                lastPanTranslation = translation
            default:
                break
            }
        }

        @objc func rotate(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastRotation = nil
            case .changed:
                guard parent.rotates else { return }
                guard let last = lastRotation else {
                    if abs(recognizer.rotation) >= Self.rotationThreshold { lastRotation = recognizer.rotation }
                    return
                }
                parent.turned(recognizer.rotation - last, recognizer.location(in: recognizer.view))
                lastRotation = recognizer.rotation
            default:
                if lastRotation != nil { parent.turnEnded() }
                lastRotation = nil
            }
        }

        @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                parent.hovered(recognizer.location(in: recognizer.view))
            default:
                parent.hovered(nil)
            }
        }

        @objc func rulerPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastRulerTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                parent.rulerMoved(CGSize(
                    width: translation.x - lastRulerTranslation.x, height: translation.y - lastRulerTranslation.y
                ))
                lastRulerTranslation = translation
            default:
                break
            }
        }

        @objc func rulerPinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastRulerScale = 1
            case .changed:
                parent.rulerResized(recognizer.scale / lastRulerScale)
                lastRulerScale = recognizer.scale
            default:
                break
            }
        }

        @objc func rulerTurn(_ recognizer: UIRotationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                parent.rulerTurnBegan()
            case .changed:
                parent.rulerTurned(recognizer.rotation, recognizer.location(in: recognizer.view))
            default:
                break
            }
        }

        @objc func undo(_ recognizer: UITapGestureRecognizer) {
            parent.undo()
        }

        @objc func redo(_ recognizer: UITapGestureRecognizer) {
            parent.redo()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A finger on the ruler, or joining one already there, is the
            // ruler's alone.
            let isRulerTouch = touch.type != .pencil && (
                rulerRecognizers.contains { $0.numberOfTouches > 0 }
                    || parent.rulerContains(touch.location(in: touch.view))
            )
            return rulerRecognizers.contains(gestureRecognizer) == isRulerTouch
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            // Two fingers tapping is an undo, not the start of a three
            // finger redo.
            gestureRecognizer.numberOfTouchesForTap == 2 && other.numberOfTouchesForTap == 3
        }
    }
}

private extension UIGestureRecognizer {
    var numberOfTouchesForTap: Int? {
        (self as? UITapGestureRecognizer)?.numberOfTouchesRequired
    }
}

/// Follows a single touch closely enough to draw with: every coalesced
/// sample, with Apple Pencil pressure and tilt. Begins at once so a stroke starts
/// where the finger landed, and cancels if a second finger arrives.
final class StrokeGestureRecognizer: UIGestureRecognizer {
    typealias Sample = StrokeSample

    /// Samples not yet handed on.
    var samples: [Sample] = []
    private(set) var lastLocation: CGPoint = .zero
    /// Whether the touch lifted close to where it landed, soon after.
    private(set) var isTap = false

    private var trackedTouch: UITouch?
    private var startLocation: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var travelled: CGFloat = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only touches meant for drawing count: a finger holding the ruler
        // doesn't stop Apple Pencil drawing along it.
        let drawing = event.allTouches?.filter { $0.gestureRecognizers?.contains(self) ?? false }.count ?? 0
        if trackedTouch != nil || touches.count > 1 || drawing > 1 {
            state = state == .possible ? .failed : .cancelled
            return
        }
        guard let touch = touches.first else { return }
        trackedTouch = touch
        startLocation = touch.location(in: view)
        lastLocation = startLocation
        startTime = touch.timestamp
        travelled = 0
        isTap = false
        samples = [sample(touch)]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        for item in coalesced {
            let location = item.location(in: view)
            travelled += hypot(location.x - lastLocation.x, location.y - lastLocation.y)
            lastLocation = location
            samples.append(sample(item))
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        lastLocation = touch.location(in: view)
        isTap = travelled < 10 && touch.timestamp - startTime < 0.35
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        samples = []
        isTap = false
    }

    private func sample(_ touch: UITouch) -> Sample {
        let isPencil = touch.type == .pencil
        let pressure: Double = isPencil && touch.maximumPossibleForce > 0
            ? Double(touch.force / touch.maximumPossibleForce) : 1
        return Sample(
            location: touch.location(in: view), pressure: pressure,
            azimuth: isPencil ? Double(touch.azimuthAngle(in: view)) : nil,
            altitude: isPencil ? Double(touch.altitudeAngle) : nil,
            time: touch.timestamp
        )
    }
}
#endif
