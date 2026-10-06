import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Props tab
//
// The scene's props JSON as a form (toggles, number fields, color wells, media
// pickers, arrays with + / −, objects as disclosure rows) or as raw JSON. Apply
// sends `setProps`; a decode error names a coding path, which is opened and
// marked in the form. Variants are named JSON files under
// `.swift-render/props/<Scene>/` that `render --props` takes as is.

struct PropsTab: View {
    @Bindable var model: ProjectModel
    @State private var savingVariant = false
    @State private var variantName = ""

    var body: some View {
        let insp = model.inspector
        if model.info?.propsJSON == nil && model.propsJSON == nil {
            StudioEmptyState(title: "No Props", symbol: "curlybraces",
                             message: "This scene isn't a PropsScene. Props scenes take a Codable payload — a launch film per product, a chart per dataset.")
                .inspectorFill()
        } else {
            VStack(spacing: 0) {
                header(insp)
                Divider()
                Group {
                    switch insp.propsMode {
                    case .form: PropsForm(model: model, insp: insp)
                    case .json: jsonEditor(insp)
                    }
                }
                .frame(maxHeight: .infinity)
                if let issue = insp.propsIssue { issueBanner(issue, insp) }
                Divider()
                footer(insp)
            }
            .onAppear { insp.syncProps() }
            .onChange(of: model.selectedScene) { _, _ in insp.syncProps() }
            .onChange(of: model.info?.propsJSON) { _, _ in insp.syncProps() }
        }
    }

    private func header(_ insp: InspectorController) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { insp.propsMode }, set: { insp.switchProps(to: $0) })) {
                ForEach(InspectorController.PropsMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help(insp.propsSyntax != nil ? "Fix the JSON to use the form" : "Edit as a form or as JSON")
            Spacer()
            Menu {
                let variants = insp.variants
                if variants.isEmpty {
                    Text("No saved variants")
                } else {
                    Section("Variants") {
                        ForEach(variants, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { Task { await insp.loadVariant(url) } }
                        }
                    }
                }
                Divider()
                Button("Load JSON File…") { chooseFile(insp) }
                Button("Reveal Variants Folder") { revealVariants() }
                Divider()
                Button("Reset to Scene Defaults") { Task { await insp.resetPropsToDefaults() } }
            } label: {
                Label("Variants", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Load a saved props variant")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func jsonEditor(_ insp: InspectorController) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: Binding(get: { insp.propsText }, set: { insp.propsText = $0 }))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.black.opacity(0.25))
            if let e = insp.propsSyntax {
                Label(e.description, systemImage: "xmark.octagon")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioStyle.bad)
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
        }
    }

    private func issueBanner(_ issue: PropsIssue, _ insp: InspectorController) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioStyle.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message).font(.system(size: 11, weight: .medium))
                if let p = issue.path, !p.components.isEmpty {
                    Text("at \(p.description)").font(StudioStyle.monoSmall).foregroundStyle(.secondary)
                }
                Text("The host kept the previous props.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(StudioStyle.bad.opacity(0.12))
    }

    private func footer(_ insp: InspectorController) -> some View {
        HStack(spacing: 6) {
            Button("Save As…") { variantName = model.selectedScene.map { "\($0)-variant" } ?? "variant"; savingVariant = true }
                .disabled(insp.editorJSON == nil)
                .help("Save these props as a named variant (render with --props)")
                .popover(isPresented: $savingVariant, arrowEdge: .bottom) { variantPopover(insp) }
            if insp.propsApplying { ProgressView().controlSize(.mini) }
            else if insp.propsEdited { Text("Edited").font(.system(size: 10.5)).foregroundStyle(StudioStyle.accent) }
            Spacer()
            Button("Revert") { insp.revertProps() }
                .disabled(!insp.propsEdited && insp.propsIssue == nil)
            Button("Apply") { Task { await insp.applyProps() } }
                .buttonStyle(.borderedProminent)
                .tint(insp.propsEdited ? StudioStyle.accent.opacity(0.85) : .gray)
                .disabled(insp.editorJSON == nil || insp.propsApplying)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func variantPopover(_ insp: InspectorController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save Props Variant").font(.headline)
            TextField("Name", text: $variantName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(save)
            Text(".swift-render/props/\(model.selectedScene ?? "Scene")/\(InspectorController.variantFileName(variantName)).json")
                .font(StudioStyle.monoSmall).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { savingVariant = false }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(InspectorController.variantFileName(variantName).isEmpty)
            }
        }
        .padding(14)
    }

    private func save() {
        if model.inspector.saveVariant(named: variantName) != nil { savingVariant = false }
    }

    private func chooseFile(_ insp: InspectorController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = model.selectedScene.map { model.project.propsVariantsDir(scene: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await insp.loadVariant(url) }
    }

    private func revealVariants() {
        guard let s = model.selectedScene else { return }
        let dir = model.project.propsVariantsDir(scene: s)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Form

struct PropsForm: View {
    @Bindable var model: ProjectModel
    let insp: InspectorController

    var body: some View {
        if let doc = insp.propsDoc {
            let rows = doc.rows(expanded: insp.propsExpanded)
            let issueRow = insp.issueRow
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text(doc.summary).font(StudioStyle.mono).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(rows) { row in
                            PropsRowView(row: row, insp: insp, project: model.project,
                                         issue: row.path == issueRow ? insp.propsIssue?.message : nil)
                                .id(row.path)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: issueRow) { _, p in if let p { withAnimation { proxy.scrollTo(p, anchor: .center) } } }
            }
        } else {
            StudioEmptyState(title: "Not an Object", symbol: "curlybraces", message: "Edit these props as JSON.")
        }
    }
}

struct PropsRowView: View {
    let row: PropsRow
    let insp: InspectorController
    let project: Project
    var issue: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                disclosure
                Text(row.label)
                    .font(.system(size: 11.5, weight: row.value.isContainer ? .semibold : .regular,
                                  design: row.isArrayElement ? .monospaced : .default))
                    .foregroundStyle(row.isArrayElement ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: labelWidth, alignment: .leading)
                    .help(row.path.description)
                control
                    .frame(maxWidth: .infinity, alignment: .trailing)
                trailing
            }
            if let issue {
                Text(issue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(StudioStyle.bad)
                    .padding(.leading, indent + 20)
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(issue != nil ? StudioStyle.bad.opacity(0.14) : hovering ? Color.white.opacity(0.035) : .clear)
        .overlay(alignment: .leading) {
            if issue != nil { Rectangle().fill(StudioStyle.bad).frame(width: 2) }
        }
        .onHover { hovering = $0 }
    }

    private var indent: CGFloat { CGFloat(row.depth) * 14 }
    private var labelWidth: CGFloat { max(54, 104 - indent * 0.5) }

    @ViewBuilder private var disclosure: some View {
        if row.value.isContainer {
            Button { insp.toggleExpanded(row.path) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(insp.propsExpanded.contains(row.path) ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder private var control: some View {
        let path = row.path
        switch row.value {
        case .null:
            Text("null").font(StudioStyle.mono).foregroundStyle(.tertiary)
        case .bool(let b):
            Toggle("", isOn: Binding(get: { b }, set: { insp.setField(path, .bool($0)) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(StudioStyle.accent)
        case .number(let lit):
            PropsNumberField(literal: lit) { insp.setField(path, .number($0)) }
        case .string(let s):
            switch row.kind {
            case .color:
                HStack(spacing: 5) {
                    PropsTextField(text: s, mono: true) { insp.setField(path, .string($0)) }.frame(width: 76)
                    ColorPicker("", selection: Binding(get: { KnobColorControl.color(s) },
                                                       set: { insp.setField(path, .string(KnobColorControl.hex($0))) }),
                                supportsOpacity: true)
                        .labelsHidden().controlSize(.small).frame(width: 34)
                }
            case .media:
                HStack(spacing: 4) {
                    PropsTextField(text: s, mono: true) { insp.setField(path, .string($0)) }
                    Button { pickMedia(current: s) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Choose a file")
                }
            default:
                PropsTextField(text: s, mono: false) { insp.setField(path, .string($0)) }
            }
        case .array(let a):
            Text(a.isEmpty ? "empty" : "\(a.count) item\(a.count == 1 ? "" : "s")")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        case .object(let o):
            Text(collapsedPreview(o)).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        if case .array(let a) = row.value {
            Button { insp.appendElement(row.path) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(a.isEmpty)
                .help(a.isEmpty ? "Add elements in JSON mode" : "Add an element (a copy of the last)")
                .frame(width: 16)
        } else if row.isArrayElement {
            Button { insp.removeElement(row.path) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)
                .help("Remove this element")
                .opacity(hovering ? 1 : 0.35)
                .frame(width: 16)
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    /// `{label "Range", value 120}` for a collapsed object.
    private func collapsedPreview(_ o: [JSONMember]) -> String {
        guard !insp.propsExpanded.contains(row.path) else { return "" }
        return o.prefix(3).map { "\($0.key) \($0.value.summary)" }.joined(separator: ", ") + (o.count > 3 ? ", …" : "")
    }

    /// Files inside the project are stored relative to its root, as scenes resolve them.
    private func pickMedia(current: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        let cur = URL(fileURLWithPath: current, relativeTo: project.root)
        panel.directoryURL = cur.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = project.root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        insp.setField(row.path, .string(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path))
    }
}

/// Number field that only accepts JSON numbers; commits on Return or focus loss.
struct PropsNumberField: View {
    var literal: String
    var commit: (String) -> Void
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .foregroundStyle(invalid ? StudioStyle.bad : .primary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(maxWidth: 110)
            .background(Color.white.opacity(focused ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(invalid ? StudioStyle.bad : .clear))
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onChange(of: literal, initial: true) { _, l in if !focused { text = l; invalid = false } }
    }

    private func apply() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != literal else { invalid = false; return }
        if JSONValue.isNumberLiteral(t) { invalid = false; commit(t) }
        else if let d = KnobCoercion.parseNumber(t), let lit = JSONValue.numberLiteral(d) { invalid = false; commit(lit) }
        else { invalid = true }
    }
}

/// Text field that writes through on every edit (props apply on ⌘↩, not per keystroke).
struct PropsTextField: View {
    var text: String
    var mono: Bool
    var commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11.5))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.white.opacity(focused ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .onChange(of: text, initial: true) { _, t in if !focused { draft = t } }
            .onChange(of: draft) { _, d in if focused, d != text { commit(d) } }   // typing only
    }
}
