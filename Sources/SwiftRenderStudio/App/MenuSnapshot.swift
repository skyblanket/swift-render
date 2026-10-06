import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Menus and confirmations in snapshots
//
//   --context-menu comment|reply|scene|section|export|clip|time|frame|knob|content|transcript
//                  [--context-menu-at x,y]       window points from the top-left
//   --confirm delete-comment|delete-reply|trash-scene|trash-export
//
// A context menu is a system window that only exists while the pointer tracks it, so
// `--context-menu` draws `MenuPreview` — the very entries the right-click would show for
// that thing (the selected comment, else the first; the open scene; the newest export…) —
// where the menu would open. `--confirm` raises the real confirmation dialog, which the
// snapshot composites like any sheet. Nothing is deleted: the snapshot window takes no input.

@MainActor
enum MenuSnapshot {
    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var contextMenu: String? { value(after: "--context-menu") }
    static var confirm: String? { value(after: "--confirm") }
    static var anchor: CGPoint? {
        let v = (value(after: "--context-menu-at") ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }

    /// `--confirm`: raise the dialog for the chosen thing and let it attach.
    static func prepare(_ model: ProjectModel) async {
        guard let kind = confirm else { return }
        let e = model.edits
        switch kind {
        case "delete-comment":
            if let c = comment(model) { e.request(.deleteComment(id: c.id)) }
        case "delete-reply":
            if let c = comment(model), let r = c.replies.first(where: ReviewController.canDelete) ?? c.replies.first {
                e.request(.deleteReply(commentID: c.id, replyID: r.id))
            }
        case "trash-scene":
            if let s = model.selectedScene { e.requestTrashScene(s) }
        case "trash-export":
            e.request(.trashExport(export(model)))
        default:
            FileHandle.standardError.write(Data("[studio] unknown --confirm \(kind) (delete-comment | delete-reply | trash-scene | trash-export)\n".utf8))
            return
        }
        if let p = e.pending {
            let t = e.confirmation(for: p)
            print("[studio] confirm: \(t.title) [\(t.button)] — \(t.message)")
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// The entries `--context-menu kind` shows, and where the menu opens by default.
    static func entries(_ kind: String, model: ProjectModel, window: NSSize) -> (entries: [StudioMenuEntry], at: CGPoint)? {
        switch kind {
        case "comment":
            guard let c = comment(model) else { return nil }
            return (ContextMenus.comment(c, model: model), CGPoint(x: window.width - 290, y: 170))
        case "reply":
            guard let c = comment(model), let r = c.replies.first(where: ReviewController.canDelete) ?? c.replies.first else { return nil }
            return (ContextMenus.reply(r, in: c, model: model), CGPoint(x: window.width - 260, y: 300))
        case "scene":
            guard let s = model.scenes.first(where: { $0.name == model.selectedScene }) ?? model.scenes.first else { return nil }
            return (ContextMenus.scene(s, model: model), CGPoint(x: 120, y: 150))
        case "section":
            return (ContextMenus.section(collapseAll: {}, expandAll: {}, anyOpen: true, anyClosed: false), CGPoint(x: 90, y: 110))
        case "export":
            return (ContextMenus.export(export(model), model: model), CGPoint(x: 120, y: window.height - 220))
        case "clip":
            guard let c = model.info?.clips.first(where: { $0.id == model.ui.selectedClipID }) ?? model.info?.clips.first else { return nil }
            return (ContextMenus.clip(c, model: model), CGPoint(x: window.width * 0.35, y: window.height - 120))
        case "time":
            return (ContextMenus.time(model.playback.t, model: model), CGPoint(x: window.width * 0.4, y: window.height - 150))
        case "frame":
            return (ContextMenus.frame(at: CGPoint(x: 0.5, y: 0.5), model: model), CGPoint(x: window.width * 0.42, y: window.height * 0.3))
        case "knob":
            guard let k = model.info?.knobs.first else { return nil }
            return (ContextMenus.knob(k, insp: model.inspector, model: model), CGPoint(x: window.width - 290, y: 200))
        case "content":
            guard let doc = model.inspector.propsDoc, case .object(let members) = doc, let first = members.first else { return nil }
            let path = PropsPath().appending(.key(first.key))
            return (ContextMenus.contentField(path, value: first.value, removable: false, insp: model.inspector, model: model),
                    CGPoint(x: window.width - 290, y: 220))
        case "transcript":
            let row = model.agent.transcript.first { !$0.files.isEmpty } ?? model.agent.transcript.first
            return (ContextMenus.transcript(text: row?.title ?? "Read AppleLaunch.swift", file: row?.files.first),
                    CGPoint(x: window.width * 0.35, y: window.height - 120))
        default:
            return nil
        }
    }

    /// The window PNG with the menu drawn where it would open.
    static func decorate(_ png: Data, window: NSWindow, model: ProjectModel) -> Data {
        guard let kind = contextMenu else { return png }
        let size = window.frame.size
        guard let (entries, defaultAt) = entries(kind, model: model, window: size) else {
            FileHandle.standardError.write(Data("[studio] --context-menu \(kind): nothing to show it for (comment | reply | scene | section | export | clip | time | frame | knob | content | transcript)\n".utf8))
            return png
        }
        print("[studio] context menu \(kind): " + entries.outline.joined(separator: " | "))
        guard let base = NSBitmapImageRep(data: png)?.cgImage,
              let menu = RenderSnapshot.renderPanel(AnyView(MenuPreview(entries: entries)), like: window) else { return png }
        let scale = window.backingScaleFactor
        let mw = CGFloat(menu.width) / scale, mh = CGFloat(menu.height) / scale
        var at = anchor ?? defaultAt
        // Like AppKit: flip left or up when the menu would leave the window.
        if at.x + mw > size.width - 4 { at.x = max(4, at.x - mw) }
        if at.y + mh > size.height - 4 { at.y = max(4, size.height - 4 - mh) }
        let rect = CGRect(x: at.x, y: size.height - at.y - mh, width: mw, height: mh)   // CG: bottom-left origin
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return png }
        let dark = window.effectiveAppearance.isDark
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.scaleBy(x: scale, y: scale)
        let shape = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(shape)
        ctx.setFillColor(dark ? CGColor(gray: 0.19, alpha: 0.98) : CGColor(gray: 0.97, alpha: 0.98))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(menu, in: rect)
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        guard let out = ctx.makeImage() else { return png }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) ?? png
    }

    private static func comment(_ model: ProjectModel) -> ReviewComment? {
        model.review.selected ?? model.review.comments.min { (model.review.number(of: $0.id) ?? 0) < (model.review.number(of: $1.id) ?? 0) }
    }

    private static func export(_ model: ProjectModel) -> URL {
        model.renders.recentOutputs(limit: 1).first ?? model.project.rendersDir.appendingPathComponent("\(model.selectedScene ?? "Scene")-master1080p60.mp4")
    }
}
