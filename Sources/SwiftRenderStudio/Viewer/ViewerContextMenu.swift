import SwiftUI

// MARK: - Viewer context menu
//
// Right-click the picture: Add Comment Here (a point pin where you clicked), Copy Frame,
// Save Frame As…, Fit / Actual Size and Show Safe Areas. A pin has its own menu (the
// comment's), which wins over this one.

struct ViewerContextMenu: ViewModifier {
    let model: ProjectModel
    var canvas: CGRect
    /// The pointer over the viewer, so the menu knows where "Here" is.
    @State private var pointer: CGPoint?

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { pointer = p } else { pointer = nil }
            }
            .contextMenu {
                StudioMenuContent(entries: ContextMenus.frame(at: Self.normalized(pointer, in: canvas), model: model))
            }
    }

    /// The pointer as a fraction of the frame (origin top-left); nil off the picture.
    static func normalized(_ p: CGPoint?, in canvas: CGRect) -> CGPoint? {
        guard let p, canvas.width > 0, canvas.height > 0, canvas.contains(p) else { return nil }
        func r4(_ v: CGFloat) -> CGFloat { (v * 10_000).rounded() / 10_000 }
        return CGPoint(x: r4((p.x - canvas.minX) / canvas.width), y: r4((p.y - canvas.minY) / canvas.height))
    }
}
