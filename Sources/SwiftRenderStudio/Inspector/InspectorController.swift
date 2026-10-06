import AppKit
import Foundation
import ImageIO
import Observation
import SwiftRenderKit

// MARK: - Inspector controller
//
// State behind the Knobs, Props and Info tabs that must outlive a tab switch:
// the paced knob sender, the props being edited, and the last `check` result.
// One per ProjectModel (`model.inspector`). Views stay thin; everything that
// talks to the host or the disk is here.

@MainActor @Observable
final class InspectorController {
    @ObservationIgnored private unowned let model: ProjectModel

    init(model: ProjectModel) {
        self.model = model
        launchPending = model.options.runCheck || !model.options.knobs.isEmpty || model.options.propsFile != nil
    }

    /// Work the snapshot runner should wait for before capturing.
    var isBusy: Bool { launchPending || checkRunning || propsApplying || knobs.isBusy }
    @ObservationIgnored private var launchPending: Bool

    /// Runs the `--knob`, `--props` and `--check` launch options once the first scene is open.
    func sceneOpened() async {
        guard launchPending, model.info != nil else { return }
        defer { launchPending = false }
        let o = model.options
        if !o.knobs.isEmpty, let info = model.info {
            for (key, text) in o.knobs.sorted(by: { $0.key < $1.key }) {
                let kind = info.knobs.first { $0.key == key }?.kind
                guard let v = kind.flatMap({ KnobCoercion.parse(text, kind: $0) }) ?? KnobCoercion.parseNumber(text).map(KnobValue.number)
                else { continue }
                model.knobValues[key] = v
            }
            knobs.submit(model.knobValues, dragging: false)
            await knobs.drain()
        }
        if let file = o.propsFile {
            let url = URL(fileURLWithPath: file, relativeTo: model.project.root)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                loadPropsEditor(text)
                await applyProps()
            } else {
                propsIssue = PropsIssue(message: "can't read \(file)", path: nil)
            }
        }
        if o.runCheck { await runCheck() }
    }

    // MARK: - Knobs

    @ObservationIgnored private(set) lazy var knobs = KnobSender { [weak self] _, dragging in
        // Send whatever is live *now*: a newer drag may have landed since this was queued.
        guard let model = self?.model else { return }
        await model.setKnobs(model.knobValues, dragging: dragging, replacing: true)
    }

    /// The value a knob shows: the live override (coerced to its kind), else its default.
    func value(_ k: KnobInfo) -> KnobValue {
        model.knobValues[k.key].flatMap { KnobCoercion.coerce($0, to: k.kind) } ?? k.defaultValue
    }

    /// Set a knob live. `dragging`: a slider is still moving (paced, no re-probe).
    func set(_ k: KnobInfo, _ v: KnobValue, dragging: Bool = false) {
        guard let v = KnobCoercion.coerce(v, to: k.kind) else { return }
        model.knobValues[k.key] = v
        knobs.submit(model.knobValues, dragging: dragging)
    }

    /// Back to the literal in the source (drops the override).
    func reset(_ k: KnobInfo) {
        model.knobValues.removeValue(forKey: k.key)
        knobs.submit(model.knobValues, dragging: false)
    }

    func isOverridden(_ k: KnobInfo) -> Bool { value(k) != k.defaultValue }

    /// The knobs file's value for `key` differs from the live one.
    func differsFromFile(_ key: String) -> Bool {
        fileValues[key] != model.knobValues[key]
    }

    var isDirty: Bool { fileValues != model.knobValues }

    /// Write the live set to `.swift-render/knobs/<Scene>.json` (defaults dropped).
    func saveKnobs() {
        guard let scene = model.selectedScene else { return }
        model.knobValues = KnobCoercion.normalized(model.knobValues, knobs: model.info?.knobs ?? [])
        model.saveKnobs()
        fileCache = nil
        model.ui.toast = model.knobValues.isEmpty ? "Cleared knobs for \(scene)" : "Saved knobs → .swift-render/knobs/\(scene).json"
    }

    /// Throw away live changes: back to what the knobs file says.
    func revertKnobs() {
        model.knobValues = fileValues
        knobs.submit(model.knobValues, dragging: false)
    }

    /// Overrides in the knobs file. Re-read when the file's mtime changes (Save,
    /// an agent's `set_knobs`, a git checkout).
    var fileValues: [String: KnobValue] {
        guard let scene = model.selectedScene else { return [:] }
        let url = model.project.knobsURL(scene: scene)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let c = fileCache, c.scene == scene, c.mtime == mtime { return c.values }
        let values = KnobFile.load(url)
        fileCache = (scene, mtime, values)
        return values
    }
    @ObservationIgnored private var fileCache: (scene: String, mtime: Date?, values: [String: KnobValue])?

    /// Knobs declared in the scene file that no probe has read yet.
    var unreachedKnobs: [DeclaredKnob] {
        guard let info = model.info, let path = info.sourcePath else { return [] }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let declared: [DeclaredKnob]
        if let c = scanCache, c.path == path, c.mtime == mtime {
            declared = c.declared
        } else {
            declared = (try? String(contentsOfFile: path, encoding: .utf8)).map(KnobSourceScan.declarations) ?? []
            scanCache = (path, mtime, declared)
        }
        let known = Set(info.knobs.map(\.key))
        return declared.filter { !known.contains($0.key) }
    }
    @ObservationIgnored private var scanCache: (path: String, mtime: Date?, declared: [DeclaredKnob])?

    // MARK: - Props

    enum PropsMode: String, CaseIterable, Identifiable { case form = "Form", json = "JSON"; var id: String { rawValue } }

    var propsMode: PropsMode = .form
    /// The form's tree (nil when the JSON text doesn't parse).
    private(set) var propsDoc: JSONValue?
    /// The JSON editor's text.
    var propsText = "" { didSet { if propsMode == .json { reparseText() } } }
    var propsExpanded: Set<PropsPath> = []
    private(set) var propsIssue: PropsIssue?
    /// A syntax error in the JSON editor (form disabled until fixed).
    private(set) var propsSyntax: JSONParseError?
    private(set) var propsApplying = false
    /// The JSON the host has; the editor is "edited" when it differs.
    private(set) var propsApplied = ""
    @ObservationIgnored private var propsScene: String?

    /// Load the scene's props into the editors when the scene changes or nothing is edited.
    func syncProps() {
        let current = model.propsJSON ?? model.info?.propsJSON
        guard let current else { return }
        if propsScene != model.selectedScene || (!propsEdited && current != propsApplied) {
            propsIssue = nil
            loadPropsEditor(current)
            propsApplied = editorJSON ?? current
        }
    }

    private func loadPropsEditor(_ text: String) {
        propsScene = model.selectedScene        // a load (variant, --props) owns the editor from here
        propsSyntax = nil
        if let doc = try? JSONValue.parse(text) {
            propsDoc = doc
            propsText = doc.pretty
            propsExpanded = doc.defaultExpanded()
        } else {
            propsMode = .json
            propsText = text
        }
    }

    private func reparseText() {
        do {
            propsDoc = try JSONValue.parse(propsText)
            propsSyntax = nil
        } catch let e as JSONParseError {
            propsSyntax = e
        } catch {}
    }

    /// What Apply would send.
    var editorJSON: String? {
        propsMode == .json ? (propsSyntax == nil ? propsText : nil) : propsDoc?.pretty
    }

    var propsEdited: Bool { (editorJSON ?? propsText) != propsApplied }

    func switchProps(to mode: PropsMode) {
        guard mode != propsMode else { return }
        if mode == .form {
            reparseText()
            guard propsSyntax == nil else { return }
        } else if let doc = propsDoc {
            propsText = doc.pretty
        }
        propsMode = mode
    }

    func setField(_ path: PropsPath, _ v: JSONValue) {
        guard var doc = propsDoc, doc.set(path, v) else { return }
        propsDoc = doc
        if propsIssue?.path.map({ $0 == path || path.ancestors.contains($0) }) == true { propsIssue = nil }
    }

    func appendElement(_ path: PropsPath) {
        guard var doc = propsDoc, doc.appendClone(at: path) else { return }
        propsDoc = doc
        propsExpanded.insert(path)
    }

    func removeElement(_ path: PropsPath) {
        guard var doc = propsDoc, doc.remove(at: path) else { return }
        propsDoc = doc
    }

    func toggleExpanded(_ path: PropsPath) {
        if propsExpanded.contains(path) { propsExpanded.remove(path) } else { propsExpanded.insert(path) }
    }

    /// Where a host error points in the form (the deepest node that exists).
    var issueRow: PropsPath? {
        guard let p = propsIssue?.path, let doc = propsDoc else { return nil }
        return doc.nearestExisting(p)
    }

    /// Send the editor's JSON to the host (`setProps`). Decode errors come back as a
    /// coding path, which is opened and highlighted in the form.
    func applyProps() async {
        guard let json = editorJSON else {
            propsIssue = PropsIssue(message: "fix the JSON syntax first", path: nil)
            return
        }
        propsApplying = true
        defer { propsApplying = false }
        do {
            try await model.setProps(json)
            propsApplied = json
            propsIssue = nil
        } catch {
            let text: String
            if case .host(let e)? = error as? HostClientError { text = e.message } else { text = HostSupervisor.describe(error) }
            propsIssue = PropsIssue.parse(text)
            if let p = issueRow { propsExpanded.formUnion(p.ancestors.dropFirst()); propsExpanded.insert(p) }
        }
    }

    /// Back to the props the host has.
    func revertProps() {
        propsIssue = nil
        loadPropsEditor(propsApplied)
    }

    /// The scene's `defaultProps`.
    func resetPropsToDefaults() async {
        propsApplying = true
        defer { propsApplying = false }
        do {
            try await model.setProps(nil)
            let json = model.info?.propsJSON ?? "{}"
            loadPropsEditor(json)
            propsApplied = editorJSON ?? json
            propsIssue = nil
        } catch {
            propsIssue = PropsIssue(message: HostSupervisor.describe(error), path: nil)
        }
    }

    // Variants: `.swift-render/props/<Scene>/<name>.json`, renderable with `--props`.

    var variants: [URL] {
        guard let scene = model.selectedScene else { return [] }
        let dir = model.project.propsVariantsDir(scene: scene)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Save the editor's JSON as a named variant; returns the file written.
    @discardableResult
    func saveVariant(named raw: String) -> URL? {
        guard let scene = model.selectedScene, let json = editorJSON else { return nil }
        let name = Self.variantFileName(raw)
        guard !name.isEmpty else { return nil }
        let url = model.project.propsVariantsDir(scene: scene).appendingPathComponent(name + ".json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (json.hasSuffix("\n") ? json : json + "\n").write(to: url, atomically: true, encoding: .utf8)
            model.ui.toast = "Saved \(scene)/\(name).json"
            return url
        } catch {
            model.ui.toast = "Couldn't save variant: \(error.localizedDescription)"
            return nil
        }
    }

    /// "Launch – EU (v2)" → "Launch-EU-v2": safe as a file name and a shell argument.
    static func variantFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let parts = raw.unicodeScalars.split { !allowed.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        return parts.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    /// Load a variant (or any JSON file) into the editor and apply it.
    func loadVariant(_ url: URL) async {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            propsIssue = PropsIssue(message: "can't read \(url.lastPathComponent)", path: nil)
            return
        }
        loadPropsEditor(text)
        await applyProps()
    }

    // MARK: - Check

    struct CheckResult {
        var scene: String
        var generation: Int
        var image: CGImage?
        var sheetPath: String
        var report: [String]
        /// Scene length the sheet was sampled over (cell i is at (i + 0.5)·duration/16).
        var duration: Double
        var at: Date
    }

    private(set) var checkRunning = false
    private(set) var check: CheckResult?
    private(set) var checkError: String?

    /// The result for the scene on screen, if any.
    var currentCheck: CheckResult? {
        guard let c = check, c.scene == model.selectedScene else { return nil }
        return c
    }

    /// Host `check`: 4×4 contact sheet, blank-frame scan and audio report.
    func runCheck() async {
        guard let scene = model.selectedScene, let host = model.host.active, !checkRunning else { return }
        checkRunning = true
        checkError = nil
        defer { checkRunning = false }
        try? model.project.ensureDotDir()
        let path = model.project.cacheDir.appendingPathComponent("check-\(scene).png").path
        let duration = model.info?.duration ?? model.playback.duration
        do {
            let reply = try await host.call(.check, HostParams(path: path))
            let out = reply.result.path ?? path
            // Same path every run: read bytes, not NSImage(contentsOf:), which may cache.
            let image = (try? Data(contentsOf: URL(fileURLWithPath: out)))
                .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            check = CheckResult(scene: scene, generation: model.host.generation, image: image, sheetPath: out,
                                report: reply.result.report ?? [], duration: duration, at: Date())
        } catch {
            checkError = HostSupervisor.describe(error)
        }
    }

    func seek(cell i: Int, of c: CheckResult) {
        model.playback.seek(ContactSheetGeometry.time(cell: i, duration: c.duration), precise: true)
    }
}

// MARK: - Contact sheet geometry

/// Mirrors `composeContactSheet` (ContactSheet.swift): `cols × rows` thumbnails,
/// 4 px gaps, a 22 px time label under each; cell i samples (i + 0.5)·duration/n.
enum ContactSheetGeometry {
    static let columns = 4, rows = 4, gap = 4.0, label = 22.0

    static func time(cell i: Int, duration: Double, count: Int = columns * rows) -> Double {
        (Double(i) + 0.5) * duration / Double(max(1, count))
    }

    /// The thumbnail rect of cell `i` in sheet pixels (top-left origin).
    static func cellRect(_ i: Int, sheet: CGSize, columns: Int = columns, rows: Int = rows) -> CGRect {
        let cw = (sheet.width - Double(columns + 1) * gap) / Double(columns)
        let ch = (sheet.height - Double(rows + 1) * gap) / Double(rows) - label
        let col = i % columns, row = i / columns
        return CGRect(x: gap + Double(col) * (cw + gap), y: gap + Double(row) * (ch + label + gap), width: cw, height: ch)
    }

    /// The cell under a point in sheet pixels (labels count as their cell; gaps don't).
    static func cell(at p: CGPoint, sheet: CGSize, columns: Int = columns, rows: Int = rows) -> Int? {
        for i in 0..<(columns * rows) {
            var r = cellRect(i, sheet: sheet, columns: columns, rows: rows)
            r.size.height += label
            if r.contains(p) { return i }
        }
        return nil
    }

    /// The cell whose sample interval holds `t`.
    static func cell(for t: Double, duration: Double, count: Int = columns * rows) -> Int? {
        guard duration > 0, t >= 0, t <= duration else { return nil }
        return min(count - 1, Int(t / duration * Double(count)))
    }
}
