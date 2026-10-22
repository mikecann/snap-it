import CoreGraphics
import Foundation

public struct EditorState: Equatable, Sendable {
    public var annotations: [Annotation] = []
    /// Non-destructive crop in image points, applied on export.
    public var crop: CGRect?

    public init(annotations: [Annotation] = [], crop: CGRect? = nil) {
        self.annotations = annotations
        self.crop = crop
    }
}

/// The editor's annotations with snapshot undo/redo. Drags update the state live with `setLive`
/// and record a single undo step with `commit(_:from:)` when they finish.
public final class AnnotationDocument {
    public let imageSize: CGSize
    public private(set) var state = EditorState()
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var savedState = EditorState()
    private var needsSave = false

    public init(imageSize: CGSize) {
        self.imageSize = imageSize
    }

    public var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    public var hasUnsavedChanges: Bool { needsSave || state != savedState }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func setLive(_ newState: EditorState) {
        state = newState
    }

    /// Makes `newState` current and records `previous` (the current state by default) as one undo step.
    public func commit(_ newState: EditorState, from previous: EditorState? = nil) {
        let before = previous ?? state
        state = newState
        guard before != newState else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    /// Records `saved` (the current state by default) as what's on disk. Call it once a write has succeeded.
    public func markSaved(_ saved: EditorState? = nil) {
        savedState = saved ?? state
        needsSave = false
    }

    /// Treats the document as unsaved even with no edits, e.g. when the first write of a capture failed.
    public func markNeedsSave() {
        needsSave = true
    }

    public func annotation(id: UUID) -> Annotation? {
        state.annotations.first { $0.id == id }
    }

    public func add(_ a: Annotation) {
        var s = state
        s.annotations.append(a)
        commit(s)
    }

    public func update(_ a: Annotation) {
        commit(Self.replacing(a, in: state))
    }

    public func remove(id: UUID) {
        var s = state
        s.annotations.removeAll { $0.id == id }
        commit(s)
    }

    public func topmostAnnotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        state.annotations.last { $0.hitTest(p, tolerance: tolerance) }
    }

    /// `state` with `a` replacing the annotation of the same id, or appended if it isn't there.
    public static func replacing(_ a: Annotation, in state: EditorState) -> EditorState {
        var s = state
        if let i = s.annotations.firstIndex(where: { $0.id == a.id }) { s.annotations[i] = a } else { s.annotations.append(a) }
        return s
    }
}
