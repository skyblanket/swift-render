import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Knobs tab
//
// A grouped form: a section per key prefix ("title.scale" → Title › Scale), each knob a
// slider with a value field, a switch, a text field or a color swatch. Changes go live
// through `InspectorController.knobs` (paced to ~30 Hz, `reprobe: false` while dragging,
// a re-probe on release). A dot marks a value that isn't saved yet; Save writes
// `.swift-render/knobs/<Scene>.json` so exports and Claude use it; Revert goes back to the
// file; the reset button (on hover) returns a knob to its default. Knobs declared in the
// scene file that no frame has read yet are listed under Not Used Yet.

/// "title.scale" → ("Title", "Scale"); "glowRadius" → ("General", "Glow Radius").
enum KnobNames {
    static func split(_ key: String) -> (section: String, label: String) {
        guard let dot = key.firstIndex(of: ".") else { return ("General", humanize(key)) }
        return (humanize(String(key[..<dot])), humanize(String(key[key.index(after: dot)...])))
    }

    /// "glowRadius" / "glow_radius" / "glow-radius" / "cta" → "Glow Radius" / "Call to Action".
    static func humanize(_ s: String) -> String {
        if let known = known[s.lowercased()] { return known }
        var words: [String] = []
        var cur = ""
        for ch in s {
            if ch == "_" || ch == "-" || ch == "." || ch == " " {
                if !cur.isEmpty { words.append(cur); cur = "" }
            } else if ch.isUppercase, let last = cur.last, last.isLowercase || last.isNumber {
                words.append(cur); cur = String(ch)
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { words.append(cur) }
        return words.enumerated().map { i, w in
            let lower = w.lowercased()
            if i > 0, ["a", "an", "and", "of", "to", "in", "on", "for", "the"].contains(lower) { return lower }
            if w.count <= 3, w == w.uppercased(), w.rangeOfCharacter(from: .letters) != nil { return w }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static let known = ["cta": "Call to Action", "url": "URL", "id": "ID", "fps": "FPS", "ui": "UI"]
}

struct KnobsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let knobs = model.info?.knobs ?? []
        let insp = model.inspector
        let unreached = insp.unreachedKnobs
        if knobs.isEmpty && unreached.isEmpty {
            StudioEmptyState(title: "No knobs yet", symbol: StudioStyle.Symbol.knobs,
                             message: "Add `Knob.double(\"speed\", 0.4, in: 0...2)` to your scene to get a live slider here.")
                .inspectorFill()
        } else {
            VStack(spacing: 0) {
                header(knobs, insp)
                Divider()
                Form {
                    ForEach(sections(knobs), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.knobs, id: \.key) { k in KnobRow(insp: insp, knob: k) }
                        }
                    }
                    if !unreached.isEmpty { unreachedSection(unreached) }
                    Section {
                        Button("Reset All to Defaults") {
                            model.knobValues = [:]
                            insp.knobs.submit([:], dragging: false)
                        }
                        .disabled(model.knobValues.isEmpty)
                        Button("Show Knobs File in Finder") {
                            if let s = model.selectedScene { SourceOpener.reveal(model.project.knobsURL(scene: s)) }
                        }
                        .disabled(insp.fileValues.isEmpty)
                    }
                    .buttonStyle(.link)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func sections(_ knobs: [KnobInfo]) -> [(title: String, knobs: [KnobInfo])] {
        var order: [String] = []
        var groups: [String: [KnobInfo]] = [:]
        for k in knobs {
            let s = KnobNames.split(k.key).section
            if groups[s] == nil { order.append(s) }
            groups[s, default: []].append(k)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private func header(_ knobs: [KnobInfo], _ insp: InspectorController) -> some View {
        let changed = knobs.filter { insp.differsFromFile($0.key) }.count
        return HStack(spacing: StudioStyle.Space.s) {
            if changed > 0 {
                Circle().fill(StudioStyle.accent).frame(width: 6, height: 6)
            }
            Text(changed == 0 ? "Saved" : "\(changed) unsaved change\(changed == 1 ? "" : "s")")
                .font(StudioStyle.Fonts.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: StudioStyle.Space.xs)
            Button("Revert") { insp.revertKnobs() }
                .disabled(!insp.isDirty)
                .help("Go back to the saved values")
            Button("Save") { insp.saveKnobs() }
                .buttonStyle(.borderedProminent)
                .disabled(!insp.isDirty)
                .keyboardShortcut("s", modifiers: [.command])
                .help("Saves so exports and Claude use these values. (⌘S)")
        }
        .controlSize(.small)
        .padding(.horizontal, StudioStyle.Space.gutter)
        .padding(.vertical, StudioStyle.Space.s)
    }

    private func unreachedSection(_ list: [DeclaredKnob]) -> some View {
        Section {
            ForEach(list, id: \.key) { d in
                LabeledContent {
                    if let path = model.info?.sourcePath {
                        Button { SourceOpener.open(file: path, line: d.line) } label: {
                            Image(systemName: StudioStyle.Symbol.reveal)
                        }
                        .buttonStyle(.borderless)
                        .help("Open line \(d.line) of \(URL(fileURLWithPath: path).lastPathComponent)")
                    }
                } label: {
                    Text(KnobNames.split(d.key).label).foregroundStyle(.secondary).help(d.key)
                }
            }
        } header: {
            Text("Not Used Yet")
        } footer: {
            Text("These haven't shown up yet. Play the film, or turn on the switch that shows them.")
                .font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - One knob

struct KnobRow: View {
    let insp: InspectorController
    let knob: KnobInfo
    @State private var hovering = false

    var body: some View {
        let v = insp.value(knob)
        let label = KnobNames.split(knob.key).label
        Group {
            switch knob.kind {
            case .double:
                VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                    HStack(spacing: 6) {
                        title(label)
                        Spacer(minLength: StudioStyle.Space.xs)
                        resetButton
                        let step = range.map(KnobCoercion.step(for:)) ?? Self.freeStep(v.doubleValue ?? 0)
                        KnobNumberField(value: v.doubleValue ?? 0, decimals: KnobCoercion.decimals(for: step)) { d in
                            insp.set(knob, .number(d))
                        }
                        if range == nil {
                            Stepper("", onIncrement: { insp.set(knob, .number(KnobCoercion.snap((v.doubleValue ?? 0) + step, step: step))) },
                                    onDecrement: { insp.set(knob, .number(KnobCoercion.snap((v.doubleValue ?? 0) - step, step: step))) })
                                .labelsHidden()
                        }
                    }
                    if let range {
                        KnobSlider(value: v.doubleValue ?? knob.defaultValue.doubleValue ?? 0, range: range,
                                   step: KnobCoercion.step(for: range)) { d, dragging in
                            insp.set(knob, .number(d), dragging: dragging)
                        }
                    }
                }
            case .bool:
                Toggle(isOn: Binding(get: { v.boolValue ?? false }, set: { insp.set(knob, .bool($0)) })) {
                    HStack(spacing: 6) { title(label); Spacer(minLength: 0); resetButton }
                }
                .toggleStyle(StudioSwitchStyle())
            case .text:
                VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                    HStack(spacing: 6) { title(label); Spacer(minLength: 0); resetButton }
                    KnobTextField(text: v.stringValue ?? "") { s, editing in insp.set(knob, .string(s), dragging: editing) }
                }
            case .color:
                HStack(spacing: 6) {
                    title(label)
                    Spacer(minLength: StudioStyle.Space.xs)
                    resetButton
                    KnobColorControl(hex: v.stringValue ?? "#FFFFFF") { hex, editing in
                        insp.set(knob, .string(hex), dragging: editing)
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .help(help)
        .studioContextMenu(ContextMenus.knob(knob, insp: insp, model: insp.projectModel))
    }

    private var help: String {
        var parts = [knob.key]
        if let range { parts.append("From \(KnobCoercion.format(range.lowerBound)) to \(KnobCoercion.format(range.upperBound))") }
        parts.append("Default \(KnobCoercion.display(knob.defaultValue))")
        return parts.joined(separator: " · ")
    }

    private func title(_ label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(insp.differsFromFile(knob.key) ? StudioStyle.accent : .clear)
                .frame(width: 6, height: 6)
                .help("Not saved yet")
            Text(label).lineLimit(1).truncationMode(.middle)
        }
    }

    private var resetButton: some View {
        Button { insp.reset(knob) } label: { Image(systemName: StudioStyle.Symbol.reset) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering && insp.isOverridden(knob) ? 1 : 0)
            .disabled(!insp.isOverridden(knob))
            .help("Back to default (\(KnobCoercion.display(knob.defaultValue)))")
    }

    private var range: ClosedRange<Double>? {
        guard let lo = knob.min, let hi = knob.max, hi > lo else { return nil }
        return lo...hi
    }

    /// Stepper increment for an unranged double: about a tenth of its magnitude.
    static func freeStep(_ v: Double) -> Double {
        let m = max(abs(v), 1)
        return KnobCoercion.step(for: 0...(m * 20))
    }
}

// MARK: - Controls

/// A slider over the knob's declared range. Reports `dragging: true` per move and a final
/// `dragging: false` on release.
struct KnobSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onChange: (Double, Bool) -> Void
    @State private var editing = false

    var body: some View {
        Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) },
                              set: { onChange(KnobCoercion.snap($0, step: step), true) }),
               in: range) { e in
            editing = e
            if !e { onChange(KnobCoercion.snap(value, step: step), false) }
        }
        .controlSize(.small)
        .labelsHidden()
    }
}

/// Numeric field: shows the live value, commits on Return or focus loss, rejects non-numbers.
struct KnobNumberField: View {
    var value: Double
    var decimals: Int
    var commit: (Double) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(StudioStyle.Fonts.callout.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .focused($focused)
            .studioField(focused: focused, invalid: invalid)
            .frame(width: 60)
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onChange(of: value, initial: true) { _, _ in if !focused { text = formatted } }
            .help(invalid ? "That isn't a number" : "")
    }

    private var formatted: String { String(format: "%.\(decimals)f", value) }

    private func apply() {
        guard text != formatted else { invalid = false; return }
        if let d = KnobCoercion.parseNumber(text) {
            invalid = false
            commit(d)
        } else {
            invalid = true
        }
    }
}

/// Live text knob: each keystroke renders (no re-probe); Return or a pause re-probes.
struct KnobTextField: View {
    var text: String
    var onChange: (String, Bool) -> Void
    @State private var draft = ""
    @State private var settle: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .font(StudioStyle.Fonts.callout)
            .lineLimit(1...4)
            .labelsHidden()
            .focused($focused)
            .studioField(focused: focused)
            .onChange(of: text, initial: true) { _, t in if !focused { draft = t } }
            .onChange(of: draft) { _, d in
                // Only typing commits: `draft` also changes when a new value arrives from outside.
                guard focused, d != text else { return }
                onChange(d, true)
                settle?.cancel()
                settle = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { onChange(d, false) } }
            }
            .onSubmit { settle?.cancel(); onChange(draft, false) }
    }
}

/// A color swatch (the system color panel). Changes stream as drags and settle into a
/// re-probe after a short pause; the hex value is in the tooltip.
struct KnobColorControl: View {
    var hex: String
    var onChange: (String, Bool) -> Void
    @State private var settle: Task<Void, Never>?

    var body: some View {
        ColorPicker("", selection: Binding(get: { Self.color(hex) }, set: { c in
            let h = Self.hex(c)
            guard h != hex else { return }
            onChange(h, true)
            settle?.cancel()
            settle = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { onChange(h, false) } }
        }), supportsOpacity: true)
        .labelsHidden()
        .help(hex)
    }

    static func color(_ hex: String) -> Color {
        guard let c = KnobCoercion.rgba(hex) else { return .white }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    static func hex(_ c: Color) -> String {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return KnobCoercion.hex(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                                b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

extension View {
    /// Inspector tab content never sets the window's minimum height: a wrapped
    /// empty-state message measured narrow did, pushing the agent panel off-screen.
    func inspectorFill() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}
