import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Context menus
//
// One builder per kind of thing. Surfaces that show the same thing call the same builder:
//
//   comment   Comments list row · viewer pin · Comments-lane marker · thread header
//   reply     a message in a thread
//   scene     sidebar row                     section   sidebar section header
//   export    sidebar Exports row · finished row in the Exports popover
//   clip      Clips lane                      time      ruler / empty lane spot
//   frame     the viewer picture              knob / content field / transcript row / file

@MainActor
enum ContextMenus {
    // MARK: Comments

    static func comment(_ c: ReviewComment, model: ProjectModel) -> [StudioMenuEntry] {
        let r = model.review, e = model.edits
        let state = CommentState(c)
        var m = StudioMenuBuilder()
        m.add("Reply", symbol: "arrowshape.turn.up.left") { e.reply(to: c.id) }
        m.add("Jump to \(StudioTime.precise(c.t))", symbol: "arrow.right.to.line") {
            r.selection = c.id
            model.playback.pause()
            model.playback.seek(c.t, precise: true)
        }
        if c.beforeAttachment != nil {
            m.add("Compare Before and After", symbol: "rectangle.split.2x1") {
                r.selection = c.id; r.compareID = c.id; model.ui.compare = model.ui.compare ?? .split
            }
        }
        m.divider()
        switch state {
        case .readyForReview:
            m.add("Looks Good", symbol: "checkmark.circle") { act(model) { try r.accept(c.id) } }
            m.add("Not Quite", symbol: "arrow.uturn.backward.circle") { act(model) { try r.reopen(c.id, note: nil) } }
        case .open, .inProgress, .claudeOnIt:
            m.add("Mark Done", symbol: "checkmark.circle") { act(model) { try r.markDone(c.id, resolution: nil) } }
            m.add("Won't Fix", symbol: "minus.circle") { act(model) { try r.setStatus(c.id, .wontFix) } }
        case .done, .wontFix:
            m.add("Reopen", symbol: "arrow.uturn.backward.circle") { act(model) { try r.reopen(c.id, note: nil) } }
        }
        m.add("Ask Claude…", symbol: "sparkles", enabled: !model.agent.isRunning) {
            r.selection = c.id
            model.perform(.askAgent)
        }
        m.divider()
        if let src = c.source {
            m.add("Open \(ReviewStyle.short(src))", symbol: "chevron.left.forwardslash.chevron.right") { SourceOpener.open(src) }
        }
        m.add("Copy Text", symbol: "doc.on.doc", shortcut: .copy) { e.copy(c.body) }
        m.add("Copy Reference", symbol: "link", help: "Scene, time and comment id") { e.copy(e.reference(c)) }
        m.divider()
        m.add("Delete Comment…", symbol: "trash", shortcut: .delete, destructive: true) { e.request(.deleteComment(id: c.id)) }
        return m.built
    }

    /// A message in a thread: copy it; a person's own reply can also be deleted.
    static func reply(_ reply: ReviewReply, in c: ReviewComment, model: ProjectModel) -> [StudioMenuEntry] {
        let e = model.edits
        var m = StudioMenuBuilder()
        m.add("Copy", symbol: "doc.on.doc") { e.copy(reply.body) }
        if ReviewController.canDelete(reply) {
            m.divider()
            m.add("Delete Reply…", symbol: "trash", destructive: true) {
                e.request(.deleteReply(commentID: c.id, replyID: reply.id))
            }
        }
        return m.built
    }

    // MARK: Sidebar

    static func scene(_ s: SceneSummary, model: ProjectModel) -> [StudioMenuEntry] {
        let e = model.edits
        var m = StudioMenuBuilder()
        m.add("Open", symbol: "play.rectangle", enabled: model.selectedScene != s.name) { e.openScene(s.name) }
        m.add("Open in \(editorName)", symbol: "chevron.left.forwardslash.chevron.right") { e.openSceneInEditor(s.name) }
        m.add("Show in Finder", symbol: "folder") { e.revealScene(s.name) }
        m.divider()
        m.add("Copy Name", symbol: "doc.on.doc") { e.copy(s.name) }
        m.add("Duplicate", symbol: "plus.square.on.square",
              help: "Copies the scene's Swift file with the scene renamed") { e.duplicateScene(s.name) }
        m.divider()
        m.add("Move to Trash…", symbol: "trash", destructive: true) { e.requestTrashScene(s.name) }
        return m.built
    }

    static var editorName: String {
        SourceOpener.preferred == .system ? "Editor" : SourceOpener.preferred.title
    }

    static func section(collapseAll: @escaping @MainActor () -> Void, expandAll: @escaping @MainActor () -> Void,
                        anyOpen: Bool, anyClosed: Bool) -> [StudioMenuEntry] {
        var m = StudioMenuBuilder()
        m.add("Collapse All", enabled: anyOpen, collapseAll)
        m.add("Expand All", enabled: anyClosed, expandAll)
        return m.built
    }

    static func export(_ url: URL, model: ProjectModel) -> [StudioMenuEntry] {
        let e = model.edits
        var m = StudioMenuBuilder()
        m.add("Open", symbol: "play.rectangle") { NSWorkspace.shared.open(url) }
        m.add("Show in Finder", symbol: "folder") { SourceOpener.reveal(url) }
        m.divider()
        m.add("Copy Path", symbol: "doc.on.doc") { e.copy(url.path) }
        // Only exports Studio keeps in out/ can be trashed from here; a file saved elsewhere
        // (Save To… outside the project) is the person's to manage in Finder.
        if (try? e.trash.validate(url, within: model.project.rendersDir)) != nil {
            m.divider()
            m.add("Move to Trash…", symbol: "trash", destructive: true) { e.request(.trashExport(url)) }
        }
        return m.built
    }

    // MARK: Timeline

    static func clip(_ c: ClipInfo, model: ProjectModel) -> [StudioMenuEntry] {
        let p = model.playback
        var m = StudioMenuBuilder()
        m.add("Jump to Start", symbol: "arrow.right.to.line") { p.seek(c.start, precise: true) }
        m.add("Select Range", symbol: "arrow.left.and.right", help: "Sets In and Out to this clip") { p.setInOut(c.start...c.end) }
        m.add("Comment on This Clip…", symbol: "text.bubble") { comment(model, t: c.start, end: c.end) }
        m.divider()
        if let src = c.source {
            m.add("Open \((src.file as NSString).lastPathComponent):\(src.line)", symbol: "chevron.left.forwardslash.chevron.right") {
                model.ui.selectedClipID = c.id
                SourceOpener.open(src)
            }
        }
        m.add("Copy Timecode", symbol: "doc.on.doc") {
            model.edits.copy("\(StudioTime.precise(c.start))–\(StudioTime.precise(c.end))")
        }
        return m.built
    }

    /// A spot on the ruler or an empty lane.
    static func time(_ t: Double, model: ProjectModel) -> [StudioMenuEntry] {
        let p = model.playback
        let io = p.inOut
        var m = StudioMenuBuilder()
        m.add("Add Comment Here", symbol: "text.bubble") { comment(model, t: t, end: nil) }
        m.divider()
        m.add("Set In Here", symbol: "arrow.right.to.line") {
            p.setInOut(t...max(t + 1.0 / Double(max(1, p.fps)), io?.upperBound ?? p.duration))
        }
        m.add("Set Out Here", symbol: "arrow.left.to.line") {
            p.setInOut(min(io?.lowerBound ?? 0, max(0, t - 1.0 / Double(max(1, p.fps))))...t)
        }
        if io != nil { m.add("Clear In and Out") { p.clearInOut() } }
        return m.built
    }

    static func comment(_ model: ProjectModel, t: Double, end: Double?, region: ReviewRegion? = nil) {
        model.playback.pause()
        model.playback.seek(t, precise: true)
        model.review.beginComment(t: t, end: end, region: region)
        model.review.threadOpen = false
        model.ui.inspectorTab = .comments
        model.ui.showInspector = true
    }

    // MARK: Viewer

    /// The picture. `point`: where the click was, normalized to the frame (nil off the frame).
    static func frame(at point: CGPoint?, model: ProjectModel) -> [StudioMenuEntry] {
        let t = model.playback.t
        let e = model.edits
        let live = model.host.active != nil && model.playback.hasFrame
        var m = StudioMenuBuilder()
        m.add("Add Comment Here", symbol: "mappin.and.ellipse") {
            let region = point.map { ReviewRegion(x: Double($0.x), y: Double($0.y), w: 0, h: 0) }
            comment(model, t: t, end: nil, region: region)
        }
        m.divider()
        m.add("Copy Frame", symbol: "doc.on.doc", enabled: live) { e.copyFrame(at: t) }
        m.add("Save Frame As…", symbol: "square.and.arrow.down", enabled: live) { e.saveFrame(at: t) }
        m.divider()
        m.add("Fit", checked: model.ui.zoom == .fit) { model.ui.zoom = .fit }
        m.add("Actual Size", checked: model.ui.zoom == .p100) { model.ui.zoom = .p100 }
        m.divider()
        m.add("Show Safe Areas", checked: model.ui.guides == .safe) {
            model.ui.guides = model.ui.guides == .safe ? .off : .safe
        }
        return m.built
    }

    // MARK: Inspector and agent

    static func knob(_ k: KnobInfo, insp: InspectorController, model: ProjectModel) -> [StudioMenuEntry] {
        var m = StudioMenuBuilder()
        m.add("Reset to Default", symbol: "arrow.counterclockwise", enabled: insp.isOverridden(k)) { insp.reset(k) }
        m.add("Copy Value", symbol: "doc.on.doc") { model.edits.copy(KnobCoercion.display(insp.value(k))) }
        if let src = k.source {
            m.divider()
            m.add("Open \(ReviewStyle.short(src))", symbol: "chevron.left.forwardslash.chevron.right") { SourceOpener.open(src) }
        }
        return m.built
    }

    /// A field on the Content tab. `removable`: it's an item in a list.
    static func contentField(_ path: PropsPath, value: JSONValue, removable: Bool,
                             insp: InspectorController, model: ProjectModel) -> [StudioMenuEntry] {
        var m = StudioMenuBuilder()
        let applied = (try? JSONValue.parse(insp.propsApplied))?[path]
        m.add("Revert Field", symbol: "arrow.counterclockwise", enabled: applied != nil && applied != value,
              help: "Back to the content the preview is showing") {
            if let applied { insp.setField(path, applied) }
        }
        m.add("Copy Value", symbol: "doc.on.doc") { model.edits.copy(value.plainText) }
        if let file = model.info?.sourcePath {
            m.divider()
            m.add("Open Scene Source", symbol: "chevron.left.forwardslash.chevron.right") { SourceOpener.open(file: file, line: 1) }
        }
        if removable {
            m.divider()
            m.add("Remove Item", symbol: "minus.circle", destructive: true) { insp.removeElement(path) }
        }
        return m.built
    }

    /// A row in Claude's transcript; `file`: the file its tool call read or wrote.
    static func transcript(text: String, file: String?) -> [StudioMenuEntry] {
        var m = StudioMenuBuilder()
        m.add("Copy", symbol: "doc.on.doc") { EditController.copyToPasteboard(text) }
        if let file { m.divider(); m.entries(for: file) }
        return m.built
    }

    /// A file Claude changed (Changed Files column).
    static func file(_ path: String) -> [StudioMenuEntry] {
        var m = StudioMenuBuilder()
        m.entries(for: path)
        m.divider()
        m.add("Copy Path", symbol: "doc.on.doc") { EditController.copyToPasteboard(path) }
        return m.built
    }

    private static func act(_ model: ProjectModel, _ f: () throws -> Void) {
        do { try f() } catch { model.ui.toast = "That didn't work. \(error)" }
    }
}

private extension StudioMenuBuilder {
    @MainActor mutating func entries(for path: String) {
        let name = (path as NSString).lastPathComponent
        add("Open \(name)", symbol: "chevron.left.forwardslash.chevron.right") { SourceOpener.open(file: path, line: 1) }
        add("Show in Finder", symbol: "folder") { SourceOpener.reveal(URL(fileURLWithPath: path)) }
    }
}

extension JSONValue {
    /// A string's text, or the JSON for anything else (what Copy Value puts on the clipboard).
    var plainText: String {
        if case .string(let s) = self { return s }
        return pretty
    }
}
