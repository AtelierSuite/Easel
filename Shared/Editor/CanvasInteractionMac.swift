#if os(macOS)
import AppKit
import Paintbrush
import SwiftUI

/// Turns the mouse, a drawing tablet and the trackpad over the canvas into
/// tool strokes and navigation, the Mac's counterpart of the touch version.
///
/// Dragging works the tool in hand, with a tablet pen's pressure and tilt.
/// Scrolling pans, and with Command or Option held zooms around the pointer;
/// pinching zooms and, when `rotates`, turning two fingers turns the view.
/// Holding the space bar makes a drag pan instead, as in other editors.
///
/// Dragging on the ruler moves it; pinching and turning over it stretch and
/// turn it.
struct CanvasInteraction: NSViewRepresentable {
    var began: (StrokeSample) -> Void
    var moved: ([StrokeSample]) -> Void
    var ended: (Bool, CGPoint) -> Void
    var cancelled: () -> Void
    /// The pointer over the canvas; nil once it leaves.
    var hovered: (CGPoint?) -> Void = { _ in /* Optional. */ }
    var zoomed: (Double, CGPoint) -> Void
    var panned: (CGSize) -> Void
    /// Whether turning two fingers on the trackpad turns the view.
    var rotates = false
    /// How far the fingers have turned since last time, and the point
    /// under the pointer.
    var turned: (Double, CGPoint) -> Void = { _, _ in /* Optional. */ }
    var turnEnded: () -> Void = { /* Optional. */ }
    var undo: () -> Void
    var redo: () -> Void
    /// Whether the pointer at a point is over the ruler.
    var rulerContains: (CGPoint) -> Bool = { _ in false }
    var rulerMoved: (CGSize) -> Void = { _ in /* Optional. */ }
    var rulerTurnBegan: () -> Void = { /* Optional. */ }
    /// How far the fingers have turned since they began, and the point
    /// under the pointer.
    var rulerTurned: (Double, CGPoint) -> Void = { _, _ in /* Optional. */ }
    var rulerResized: (Double) -> Void = { _ in /* Optional. */ }
    /// Whether the tool in hand draws its own outline under the pointer, in
    /// place of the system's cursor.
    var drawsOwnCursor = false

    /// The same, with the system's cursor left out while the tool in hand
    /// draws its own outline under the pointer.
    func drawingOwnCursor(_ draws: Bool) -> Self {
        var interaction = self
        interaction.drawsOwnCursor = draws
        return interaction
    }

    func makeNSView(context: Context) -> CanvasInputView {
        let view = CanvasInputView()
        view.interaction = self
        return view
    }

    func updateNSView(_ view: CanvasInputView, context: Context) {
        view.interaction = self
        // A tool picked while the pointer rests on the canvas.
        view.refreshCursor()
    }
}

/// The view under the canvas that takes its events.
final class CanvasInputView: NSView {
    var interaction: CanvasInteraction?

    private enum Drag {
        case stroke(start: CGPoint, startTime: TimeInterval, travelled: CGFloat, last: CGPoint)
        case pan(last: CGPoint)
        case ruler(last: CGPoint)
    }

    private var drag: Drag?
    private var isSpaceDown = false
    /// Whether the gesture under way began over the ruler.
    private var gestureIsOnRuler = false
    /// How far the fingers have turned since they began.
    private var rotation = 0.0
    /// Whether the fingers have turned far enough to mean it, so a pinch
    /// doesn't wobble the view.
    private var isTurning = false
    private static let rotationThreshold = Double.pi / 18
    private var trackingArea: NSTrackingArea?

    /// The menu a right-click on the canvas brings up, which the app sets.
    static var contextMenu: (@MainActor () -> NSMenu)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { Self.contextMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    /// Whether the system's pointer is hidden while the tool draws its own.
    /// Hidden outright rather than swapped for a blank cursor, as the
    /// SwiftUI views around the canvas set the arrow back as the pointer
    /// moves. Every hide is matched by an unhide.
    private var hidesPointer = false {
        didSet {
            guard hidesPointer != oldValue else { return }
            if hidesPointer { NSCursor.hide() } else { NSCursor.unhide() }
        }
    }

    private func updateCursor() {
        if isSpaceDown || drag.map({ if case .pan = $0 { true } else { false } }) == true {
            hidesPointer = false
            (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set()
            return
        }
        let isOverRuler: Bool
        switch drag {
        case .ruler: isOverRuler = true
        case .stroke: isOverRuler = false
        default:
            isOverRuler = window.map { interaction?.rulerContains(location(ofWindowPoint: $0.mouseLocationOutsideOfEventStream)) } == true
        }
        hidesPointer = interaction?.drawsOwnCursor == true && !isOverRuler
        NSCursor.crosshair.set()
    }

    /// Brings the pointer back as it leaves the canvas.
    private func leaveCanvas() {
        hidesPointer = false
        NSCursor.arrow.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hidesPointer = false }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
    }

    /// Another window or app in front gets the pointer back.
    @objc private func windowResignedKey(_ notification: Notification) {
        hidesPointer = false
    }

    /// Whether the pointer is over the canvas itself, not the tools
    /// floating over it.
    private var isPointerOverCanvas: Bool {
        guard let window, let hit = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// Puts the right cursor up if the pointer is over the canvas itself,
    /// such as when the tool in hand changes.
    func refreshCursor() {
        guard window?.isKeyWindow == true, drag == nil else { return }
        if isPointerOverCanvas { updateCursor() } else { hidesPointer = false }
    }

    private func location(ofWindowPoint point: NSPoint) -> CGPoint {
        convert(point, from: nil)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// A tablet pen's pressure and tilt; a mouse or trackpad presses fully.
    private func sample(_ event: NSEvent) -> StrokeSample {
        var sample = StrokeSample(location: location(of: event), pressure: 1, time: event.timestamp)
        if event.subtype == .tabletPoint {
            sample.pressure = Double(event.pressure)
            let tilt = event.tilt
            let lean = min(hypot(tilt.x, tilt.y), 1)
            if lean > 0.01 {
                // Tilt runs y up; the canvas runs y down.
                sample.azimuth = atan2(-tilt.y, tilt.x)
            }
            sample.altitude = (1 - lean) * .pi / 2
        }
        return sample
    }

    // MARK: Mouse and pen

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A Control-click is a right-click, not a stroke.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let interaction else { return }
        let point = location(of: event)
        if isSpaceDown {
            drag = .pan(last: point)
            updateCursor()
        } else if interaction.rulerContains(point) {
            drag = .ruler(last: point)
        } else {
            drag = .stroke(start: point, startTime: event.timestamp, travelled: 0, last: point)
            interaction.began(sample(event))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction, let drag else { return }
        let point = location(of: event)
        switch drag {
        case .stroke(let start, let startTime, let travelled, let last):
            self.drag = .stroke(start: start, startTime: startTime, travelled: travelled + hypot(point.x - last.x, point.y - last.y), last: point)
            interaction.moved([sample(event)])
        case .pan(let last):
            self.drag = .pan(last: point)
            interaction.panned(CGSize(width: point.x - last.x, height: point.y - last.y))
        case .ruler(let last):
            self.drag = .ruler(last: point)
            interaction.rulerMoved(CGSize(width: point.x - last.x, height: point.y - last.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction, let drag else { return }
        self.drag = nil
        let point = location(of: event)
        if case .stroke(_, let startTime, let travelled, _) = drag {
            let isTap = travelled < 4 && event.timestamp - startTime < 0.35
            interaction.ended(isTap, point)
        }
        // A stroke may end off the canvas.
        if isPointerOverCanvas { updateCursor() } else { leaveCanvas() }
    }

    override func mouseMoved(with event: NSEvent) {
        // The brush's outline follows the pointer only over the canvas
        // itself, not over the bars and tools floating on it.
        interaction?.hovered(isPointerOverCanvas ? location(of: event) : nil)
        // The ruler may have come or gone from under the pointer, or the
        // pointer onto the tools floating over the canvas, which take no
        // part in the canvas's cursor.
        if isPointerOverCanvas { updateCursor() } else { leaveCanvas() }
    }

    override func mouseExited(with event: NSEvent) {
        interaction?.hovered(nil)
        if drag == nil { leaveCanvas() }
    }

    override func tabletProximity(with event: NSEvent) {
        if !event.isEnteringProximity { interaction?.hovered(nil) }
    }

    /// Escape abandons the stroke under way.
    override func cancelOperation(_ sender: Any?) {
        guard case .stroke = drag else { return }
        drag = nil
        interaction?.cancelled()
    }

    // MARK: Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        guard let interaction else { return }
        // A wheel scrolls in lines; a trackpad in points.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            interaction.zoomed(exp(Double(dy) * 0.01), location(of: event))
        } else {
            interaction.panned(CGSize(width: dx, height: dy))
        }
    }

    override func magnify(with event: NSEvent) {
        guard let interaction else { return }
        let point = location(of: event)
        if event.phase == .began { gestureIsOnRuler = interaction.rulerContains(point) }
        let factor = 1 + Double(event.magnification)
        if gestureIsOnRuler {
            interaction.rulerResized(factor)
        } else {
            interaction.zoomed(factor, point)
        }
    }

    override func rotate(with event: NSEvent) {
        guard let interaction else { return }
        let point = location(of: event)
        // Degrees anticlockwise; the canvas turns clockwise in radians.
        let change = -Double(event.rotation) * .pi / 180
        switch event.phase {
        case .began:
            gestureIsOnRuler = interaction.rulerContains(point)
            isTurning = false
            rotation = 0
            if gestureIsOnRuler { interaction.rulerTurnBegan() }
        case .changed:
            rotation += change
            if gestureIsOnRuler {
                interaction.rulerTurned(rotation, point)
            } else if interaction.rotates {
                if isTurning {
                    interaction.turned(change, point)
                } else if abs(rotation) >= Self.rotationThreshold {
                    isTurning = true
                }
            }
        default:
            if isTurning { interaction.turnEnded() }
            isTurning = false
            gestureIsOnRuler = false
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            if !event.isARepeat {
                isSpaceDown = true
                updateCursor()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            isSpaceDown = false
            updateCursor()
            return
        }
        super.keyUp(with: event)
    }
}
#endif
