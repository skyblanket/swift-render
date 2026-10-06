import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Knobs tab   // S7
//
// One row per `SceneInfo.knobs` entry: a slider + field for ranged doubles, a
// toggle, a text field, or a color well. Changes go live through
// `InspectorController.knobs` (paced to ~30 Hz, `reprobe: false` while dragging,
// a re-probe on release). ● marks a value the knobs file doesn't have yet; Save
// writes `.swift-render/knobs/<Scene>.json`, Revert goes back to it, ↺ returns a
// knob to its source literal and ↗ opens that line. Knobs declared in the scene
// file that no probe has read are listed as "not reached yet".

struct KnobsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let knobs = model.info?.knobs ?? []
        let insp = model.inspector
        let unreached = insp.unreachedKnobs
        if knobs.isEmpty && unreached.isEmpty {
            StudioEmptyState(title: "No Knobs", symbol: "slider.horizontal.3",
                             message: "Declare tunables in the scene with Knob.double(\"key\", 0.4, in: 0...2).")
        } else {
            VStack(spacing: 0) {
                header(knobs, insp)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(knobs, id: \.key) { k in
                            KnobRow(insp: insp, knob: k)
                            Rectangle().fill(StudioStyle.hairline).frame(height: 1).padding(.leading, 12)
                        }
                        if !unreached.isEmpty { unreachedSection(unreached) }
                    }
                }
                Divider()
                footer(insp)
            }
        }
    }

    private func header(_ knobs: [KnobInfo], _ insp: InspectorController) -> some View {
        let changed = knobs.filter { insp.differsFromFile($0.key) }.count
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(knobs.count) knob\(knobs.count == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold))
                Text(changed == 0 ? "matches knobs file" : "\(changed) unsaved change\(changed == 1 ? "" : "s")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(changed == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(StudioStyle.accent))
            }
            Spacer()
            Menu {
                Button("Reset All to Source Defaults") {
                    model.knobValues = [:]
                    insp.knobs.submit([:], dragging: false)
                }
                .disabled(model.knobValues.isEmpty)
                Button("Reveal Knobs File in Finder") {
                    if let s = model.selectedScene { SourceOpener.reveal(model.project.knobsURL(scene: s)) }
                }
                .disabled(insp.fileValues.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            Button("Revert") { insp.revertKnobs() }
                .disabled(!insp.isDirty)
                .help("Back to the values in the knobs file")
            Button("Save") { insp.saveKnobs() }
                .buttonStyle(.borderedProminent)
                .tint(insp.isDirty ? StudioStyle.accent.opacity(0.85) : .gray)
                .disabled(!insp.isDirty)
                .keyboardShortcut("s", modifiers: [.command])
                .help("Write .swift-render/knobs/\(model.selectedScene ?? "Scene").json (renders and agents read it)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func unreachedSection(_ list: [DeclaredKnob]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOT REACHED YET").font(StudioStyle.laneLabel).foregroundStyle(.secondary)
            Text("Declared in the scene file, but no frame has read \(list.count == 1 ? "it" : "them") yet — play or flip the switch that guards \(list.count == 1 ? "it" : "them").")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(list, id: \.key) { d in
                HStack(spacing: 6) {
                    Image(systemName: KnobRow.icon(d.kind)).foregroundStyle(.tertiary).frame(width: 14)
                    Text(d.key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    if let path = model.info?.sourcePath {
                        Button {
                            SourceOpener.open(file: path, line: d.line)
                        } label: {
                            Text("\(URL(fileURLWithPath: path).lastPathComponent):\(d.line)").font(StudioStyle.monoSmall)
                        }
                        .buttonStyle(.link)
                        .help("Open the declaration")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func footer(_ insp: InspectorController) -> some View {
        HStack(spacing: 5) {
            Circle().fill(StudioStyle.accent).frame(width: 6, height: 6)
            Text("not in knobs file").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Image(systemName: "arrow.counterclockwise").imageScale(.small).foregroundStyle(.secondary)
            Text("source default").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - One knob

struct KnobRow: View {
    let insp: InspectorController
    let knob: KnobInfo

    var body: some View {
        let v = insp.value(knob)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(insp.differsFromFile(knob.key) ? StudioStyle.accent : .clear)
                    .frame(width: 6, height: 6)
                    .help("Live value isn't in the knobs file yet")
                Text(knob.key)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(knob.key)
                Spacer(minLength: 4)
                inlineControl(v)
                actions
            }
            if case .double = knob.kind, let range = range {
                KnobSlider(value: v.doubleValue ?? knob.defaultValue.doubleValue ?? 0, range: range,
                           step: KnobCoercion.step(for: range)) { d, dragging in
                    insp.set(knob, .number(d), dragging: dragging)
                }
                .padding(.leading, 12)
            }
            if case .text = knob.kind {
                KnobTextField(text: v.stringValue ?? "") { s, editing in insp.set(knob, .string(s), dragging: editing) }
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset to Source Default") { insp.reset(knob) }.disabled(!insp.isOverridden(knob))
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(KnobCoercion.display(v), forType: .string)
            }
            if let src = knob.source { Button("Open Source") { SourceOpener.open(src) } }
        }
    }

    private var range: ClosedRange<Double>? {
        guard let lo = knob.min, let hi = knob.max, hi > lo else { return nil }
        return lo...hi
    }

    @ViewBuilder private func inlineControl(_ v: KnobValue) -> some View {
        switch knob.kind {
        case .double:
            let step = range.map(KnobCoercion.step(for:)) ?? Self.freeStep(v.doubleValue ?? 0)
            KnobNumberField(value: v.doubleValue ?? 0, decimals: KnobCoercion.decimals(for: step),
                            highlighted: insp.isOverridden(knob)) { d in insp.set(knob, .number(d)) }
            if range == nil {
                Stepper("", onIncrement: { insp.set(knob, .number(KnobCoercion.snap((v.doubleValue ?? 0) + step, step: step))) },
                        onDecrement: { insp.set(knob, .number(KnobCoercion.snap((v.doubleValue ?? 0) - step, step: step))) })
                    .labelsHidden()
                    .controlSize(.mini)
            }
        case .bool:
            Toggle("", isOn: Binding(get: { v.boolValue ?? false }, set: { insp.set(knob, .bool($0)) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(StudioStyle.accent)
        case .text:
            EmptyView()
        case .color:
            KnobColorControl(hex: v.stringValue ?? "#FFFFFF") { hex, editing in
                insp.set(knob, .string(hex), dragging: editing)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button { insp.reset(knob) } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset to the source default (\(KnobCoercion.display(knob.defaultValue)))")
                .opacity(insp.isOverridden(knob) ? 1 : 0)
                .disabled(!insp.isOverridden(knob))
            Button { if let s = knob.source { SourceOpener.open(s) } } label: { Image(systemName: "arrow.up.forward.square") }
                .help(knob.source.map { "Open \(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line)" } ?? "No source location")
                .disabled(knob.source == nil)
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
        .foregroundStyle(.secondary)
    }

    /// Stepper increment for an unranged double: about a tenth of its magnitude.
    static func freeStep(_ v: Double) -> Double {
        let m = max(abs(v), 1)
        return KnobCoercion.step(for: 0...(m * 20))
    }

    static func icon(_ k: KnobInfo.Kind) -> String {
        switch k {
        case .double: return "dial.medium"
        case .bool: return "switch.2"
        case .text: return "textformat"
        case .color: return "paintpalette"
        }
    }
}

// MARK: - Controls

/// A slider over the knob's declared range with min/max labels. Reports
/// `dragging: true` per move and a final `dragging: false` on release.
struct KnobSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onChange: (Double, Bool) -> Void
    @State private var editing = false

    var body: some View {
        let decimals = KnobCoercion.decimals(for: step)
        HStack(spacing: 6) {
            Text(String(format: "%.\(decimals)f", range.lowerBound)).font(StudioStyle.monoSmall).foregroundStyle(.tertiary)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) },
                                  set: { onChange(KnobCoercion.snap($0, step: step), true) }),
                   in: range) { e in
                editing = e
                if !e { onChange(KnobCoercion.snap(value, step: step), false) }
            }
            .controlSize(.mini)
            .tint(StudioStyle.accent)
            Text(String(format: "%.\(decimals)f", range.upperBound)).font(StudioStyle.monoSmall).foregroundStyle(.tertiary)
        }
    }
}

/// Numeric field: shows the live value, commits on Return or focus loss, rejects non-numbers.
struct KnobNumberField: View {
    var value: Double
    var decimals: Int
    var highlighted: Bool
    var commit: (Double) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .foregroundStyle(invalid ? StudioStyle.bad : highlighted ? StudioStyle.accent : .primary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(width: 58)
            .background(Color.white.opacity(focused ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? StudioStyle.bad : .clear))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onChange(of: value, initial: true) { _, _ in if !focused { text = formatted } }
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
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.white.opacity(focused ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 5))
            .focused($focused)
            .onChange(of: text, initial: true) { _, t in if !focused { draft = t } }
            .onChange(of: draft) { _, d in
                guard d != text else { return }
                onChange(d, true)
                settle?.cancel()
                settle = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { onChange(d, false) } }
            }
            .onSubmit { settle?.cancel(); onChange(draft, false) }
    }
}

/// Color well + hex field. The system color panel streams changes, so they go out as
/// drags and settle into a re-probe after a short pause.
struct KnobColorControl: View {
    var hex: String
    var onChange: (String, Bool) -> Void
    @State private var settle: Task<Void, Never>?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 66)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.white.opacity(focused ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 4))
                .focused($focused)
                .onSubmit { if let h = KnobCoercion.normalizeHex(text) { onChange(h, false) } else { text = hex } }
                .onChange(of: hex, initial: true) { _, h in if !focused { text = h } }
            ColorPicker("", selection: Binding(get: { Self.color(hex) }, set: { c in
                let h = Self.hex(c)
                guard h != hex else { return }
                onChange(h, true)
                settle?.cancel()
                settle = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { onChange(h, false) } }
            }), supportsOpacity: true)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 34)
        }
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
