import SwiftUI

/// Undo and redo for a composition.
///
/// Every change, however it was made, passes through `record(from:to:)`,
/// which registers the composition as it was with the undo manager.
/// Snapshots rather than inverse operations: layers share their pixels by
/// reference, so a snapshot costs only the images the change replaced, and
/// no edit can forget to be undoable.
@MainActor
@Observable
final class CompositionHistory {
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// What each step did, oldest first: the first is how the picture was
    /// when it was opened, or the oldest step still kept.
    private(set) var steps: [String] = [String(localized: "History.Opened")]
    /// Which of `steps` the picture is at now; later ones can be redone.
    private(set) var position = 0
    /// The picture as it was opened, to compare against.
    private(set) var original: Composition?

    /// How long a pause ends a run of changes that would otherwise be one
    /// step, such as dragging an opacity slider.
    static let coalescingInterval: TimeInterval = 1
    /// Each step can hold a full-size copy of a layer, so the history is
    /// kept short enough to stay within memory.
    static let levels = 40

    /// The editor's own undo manager. Not the window's: a document window's
    /// undo manager also gets a step of SwiftUI's for every change to the
    /// document, and undoing one of those rewinds the file by a single frame
    /// of a drag rather than by the user's whole edit.
    @ObservationIgnored private let fallbackManager = UndoManager()
    @ObservationIgnored private weak var attachedManager: UndoManager?
    @ObservationIgnored private var read: () -> Composition = { .blank() }
    @ObservationIgnored private var write: (Composition) -> Void = { _ in /* Replaced on attach. */ }
    /// Told after an undo or redo has put a composition back.
    @ObservationIgnored private var restored: (Composition) -> Void = { _ in /* Replaced on attach. */ }

    /// The composition an undo or redo has just written. SwiftUI reports the
    /// change a moment later; recognising it keeps that report off the stack.
    @ObservationIgnored private var restoring: Composition?
    @ObservationIgnored private var lastScope: EditScope?
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Whether a change has been registered in the undo group still open.
    /// The undo manager groups every change in one event into a step, and
    /// the list of steps follows it.
    @ObservationIgnored private var groupIsOpen = false

    private var undoManager: UndoManager? { attachedManager ?? fallbackManager }

    func attach(
        to undoManager: UndoManager?,
        read: @escaping () -> Composition,
        write: @escaping (Composition) -> Void,
        restored: @escaping (Composition) -> Void
    ) {
        self.read = read
        self.write = write
        self.restored = restored
        if original == nil { original = read() }
        let manager = undoManager ?? fallbackManager
        guard manager !== attachedManager else { return }
        attachedManager = manager
        observers.forEach(NotificationCenter.default.removeObserver)
        manager.levelsOfUndo = Self.levels
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] notification in
                let closed = notification.name == .NSUndoManagerDidCloseUndoGroup
                MainActor.assumeIsolated {
                    if closed { self?.groupIsOpen = false }
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// Notes a change the user made, unless it is one an undo or redo made.
    /// `tool` is the one in hand, which names a change to a layer's pixels.
    func record(from old: Composition, to new: Composition, tool: Tool? = nil) {
        if let restoring {
            self.restoring = nil
            if restoring == new { return }
        }
        guard let undoManager, old != new else { return }

        let scope = EditScope(from: old, to: new)
        let now = Date()
        defer {
            lastScope = scope
            lastChange = now
        }
        if scope.coalesces, scope == lastScope, undoManager.canUndo,
           now.timeIntervalSince(lastChange) < Self.coalescingInterval {
            return
        }
        register(restoring: old, with: undoManager)
        let name = HistoryNaming.name(from: old, to: new, tool: tool)
        if groupIsOpen, position > 0 {
            // Part of the same step as the change before it.
            steps[position] = name
            refresh()
            return
        }
        groupIsOpen = true
        // A new step drops whatever could have been redone.
        steps = Array(steps.prefix(position + 1)) + [name]
        position += 1
        // The undo manager forgets the oldest steps past its limit.
        let overflow = steps.count - (Self.levels + 1)
        if overflow > 0 {
            steps.removeFirst(overflow)
            position -= overflow
        }
        refresh()
    }

    func undo() {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        groupIsOpen = false
        position = max(0, position - 1)
        refresh()
    }

    func redo() {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        groupIsOpen = false
        position = min(steps.count - 1, position + 1)
        refresh()
    }

    /// Goes back or forward to just after step `index`.
    func jump(to index: Int) {
        while position > index, canUndo { undo() }
        while position < index, canRedo { redo() }
    }

    /// Run from inside an undo, the inverse it registers lands on the redo
    /// stack, and the other way round.
    private func register(restoring target: Composition, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                        let current = history.read()
                history.register(restoring: current, with: undoManager)
                history.lastScope = nil
                history.restoring = target
                history.write(target)
                history.restored(target)
            }
        }
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

/// What kind of change separates two compositions, so a run of the same
/// small change — a slider being dragged, text being typed — is one step.
struct EditScope: Equatable {
    enum Kind: Equatable {
        case opacity, blendMode, transform, text, vector, filters, effects, name, visibility, other
    }

    var layerID: Layer.ID?
    var kind: Kind

    init(from old: Composition, to new: Composition) {
        if old.size == new.size, old.layers == new.layers, old.groups.map(\.id) == new.groups.map(\.id) {
            // A group's opacity slider or name: a run of them is one step.
            let changed = zip(old.groups, new.groups).first { $0 != $1 }
            if let (before, after) = changed, before.isVisible == after.isVisible, before.isExpanded == after.isExpanded {
                self.init(layerID: after.id, kind: before.opacity != after.opacity ? .opacity : .name)
                return
            }
        }
        guard old.size == new.size, old.layers.map(\.id) == new.layers.map(\.id) else {
            self.init(layerID: nil, kind: .other)
            return
        }
        let changed = zip(old.layers, new.layers).filter { $0 != $1 }
        guard changed.count == 1, let (before, after) = changed.first else {
            self.init(layerID: nil, kind: .other)
            return
        }
        let kind: Kind
        if before.text != after.text {
            kind = .text
        } else if before.vector != after.vector {
            // A handle being dragged; adding or removing a point changes
            // the count and is a step of its own.
            kind = before.vector?.paths.map(\.nodes.count) == after.vector?.paths.map(\.nodes.count) ? .vector : .other
        } else if before.image != after.image {
            kind = .other
        } else if before.filters != after.filters {
            // Only a slider moving: adding, removing or reordering filters
            // changes their count or order and is a step of its own.
            kind = before.filters.map(\.id) == after.filters.map(\.id)
                && before.filters.map(\.isEnabled) == after.filters.map(\.isEnabled) ? .filters : .other
        } else if before.effects != after.effects {
            // Only a slider moving, as for filters.
            kind = before.effects.map(\.id) == after.effects.map(\.id)
                && before.effects.map(\.isEnabled) == after.effects.map(\.isEnabled) ? .effects : .other
        } else if before.isClipped != after.isClipped {
            kind = .other
        } else if before.opacity != after.opacity {
            kind = .opacity
        } else if before.blendMode != after.blendMode {
            kind = .blendMode
        } else if before.transform != after.transform {
            kind = .transform
        } else if before.name != after.name {
            kind = .name
        } else {
            kind = .visibility
        }
        self.init(layerID: after.id, kind: kind)
    }

    init(layerID: Layer.ID?, kind: Kind) {
        self.layerID = layerID
        self.kind = kind
    }

    /// Pixel edits and structural changes are always steps of their own.
    var coalesces: Bool {
        switch kind {
        case .opacity, .transform, .text, .vector, .filters, .effects, .name: return true
        case .blendMode, .visibility, .other: return false
        }
    }
}
