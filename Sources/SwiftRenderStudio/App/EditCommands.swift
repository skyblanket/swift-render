import AppKit
import SwiftUI

// MARK: - Edit menu, confirmations and undo for the project window
//
// - The one confirmation dialog for every destructive menu command (`model.edits.pending`):
//   a destructive button that names the action, Cancel as the default.
// - The window's UndoManager is handed to `EditController`, so Edit › Undo / Redo (⌘Z, ⇧⌘Z)
//   reverse deletes and Trash moves, with "Undo Delete Comment" style titles.
// - `EditResponder` sits after the window in the responder chain. Edit › Copy and Edit ›
//   Delete reach it only when nothing in front handles them (a text field copies its own
//   selection first), and then act on the selected comment. No new key equivalents: the
//   standard Edit menu items are the only bindings.

struct ProjectEditing: ViewModifier {
    @Bindable var model: ProjectModel
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        let edits = model.edits
        let text = edits.pending.map { edits.confirmation(for: $0) }
        content
            .confirmationDialog(text?.title ?? "", isPresented: Binding(
                get: { edits.pending != nil },
                set: { if !$0 { edits.pending = nil } }), titleVisibility: .visible) {
                Button(text?.button ?? "Delete", role: .destructive) { edits.confirm() }
                Button("Cancel", role: .cancel) { edits.pending = nil }
            } message: {
                Text(text?.message ?? "")
            }
            .onAppear { edits.undoManager = undoManager }
            .onChange(of: undoManager) { _, um in edits.undoManager = um }
    }
}

/// Edit › Copy and Edit › Delete for the selected comment, after everything in the window
/// had its chance (text fields and lists handle their own first).
final class EditResponder: NSResponder, NSMenuItemValidation {
    private weak var model: ProjectModel?

    init(model: ProjectModel) {
        self.model = model
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    private static var ownerKey: UInt8 = 0

    /// Inserts itself right after `window` (keeping whatever followed it). `nextResponder`
    /// doesn't retain, so the window owns the responder (an associated object).
    @MainActor static func install(model: ProjectModel, in window: NSWindow) {
        if window.nextResponder is EditResponder { return }
        let r = EditResponder(model: model)
        r.nextResponder = window.nextResponder
        window.nextResponder = r
        objc_setAssociatedObject(window, &ownerKey, r, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @MainActor private var selected: (model: ProjectModel, id: String)? {
        guard let m = model, let id = m.review.selection, m.review.comments.contains(where: { $0.id == id }) else { return nil }
        return (m, id)
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let (m, id) = selected, let c = m.review.comments.first(where: { $0.id == id }) else { return }
            m.edits.copy(c.body)
        }
    }

    @objc func delete(_ sender: Any?) {
        MainActor.assumeIsolated { model?.edits.deleteSelection() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch item.action {
            case #selector(copy(_:)), #selector(delete(_:)): return selected != nil
            default: return true
            }
        }
    }
}
