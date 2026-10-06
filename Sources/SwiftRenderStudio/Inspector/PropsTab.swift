import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Content tab
//
// The scene's props (its words, images and settings) as a grouped form, or as raw JSON.
// Top-level values come first; each object or list gets its own section; list items are
// titled by their first piece of text ("swift-render 0.10"), never by index. Apply sends
// `setProps`; a decode error names a coding path, which is opened and marked in the form.
// Versions are named JSON files under `.swift-render/props/<Scene>/` that
// `render --props` takes as is.

struct PropsTab: View {
    @Bindable var model: ProjectModel
    @State private var savingVariant = false
    @State private var variantName = ""

    var body: some View {
        let insp = model.inspector
        if model.info?.propsJSON == nil && model.propsJSON == nil {
            StudioEmptyState(title: "Nothing to edit here", symbol: StudioStyle.Symbol.content,
                             message: "This scene's words and images live in its code. Launch films keep theirs here so you can edit them without code.")
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
        HStack(spacing: StudioStyle.Space.s) {
            StudioSegmented(options: InspectorController.PropsMode.allCases,
                            selection: Binding(get: { insp.propsMode }, set: { insp.switchProps(to: $0) })) { $0.rawValue }
            .fixedSize()
            .help(insp.propsSyntax != nil ? "Fix the JSON to use the form" : "Edit as a form or as JSON")
            Spacer()
            Menu {
                let variants = insp.variants
                if variants.isEmpty {
                    Text("No saved versions yet")
                } else {
                    Section("Versions") {
                        ForEach(variants, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { Task { await insp.loadVariant(url) } }
                        }
                    }
                }
                Divider()
                Button("Open JSON File…") { chooseFile(insp) }
                Button("Show Versions in Finder") { revealVariants() }
                Divider()
                Button("Reset to Defaults") { Task { await insp.resetPropsToDefaults() } }
            } label: {
                Text("Versions")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Load a saved version")
        }
        .controlSize(.small)
        .padding(.horizontal, StudioStyle.Space.gutter)
        .padding(.vertical, StudioStyle.Space.s)
    }

    private func jsonEditor(_ insp: InspectorController) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: Binding(get: { insp.propsText }, set: { insp.propsText = $0 }))
                .font(StudioStyle.Fonts.code)
                .scrollContentBackground(.hidden)
                .padding(StudioStyle.Space.s)
                .background(StudioStyle.raised)
            if let e = insp.propsSyntax {
                Label(e.description, systemImage: StudioStyle.Symbol.error)
                    .font(StudioStyle.Fonts.subheadline)
                    .foregroundStyle(StudioStyle.error)
                    .padding(.horizontal, StudioStyle.Space.gutter).padding(.vertical, StudioStyle.Space.xs)
            }
        }
    }

    private func issueBanner(_ issue: PropsIssue, _ insp: InspectorController) -> some View {
        HStack(alignment: .top, spacing: StudioStyle.Space.s) {
            Image(systemName: StudioStyle.Symbol.error).foregroundStyle(StudioStyle.error)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message.prefix(1).uppercased() + issue.message.dropFirst()).font(StudioStyle.Fonts.calloutEmphasis)
                if let p = issue.path, !p.components.isEmpty {
                    Text("In \(PropsForm.title(for: p))").font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
                }
                Text("Studio kept the last version that worked.").font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, StudioStyle.Space.gutter).padding(.vertical, StudioStyle.Space.s)
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
    }

    private func footer(_ insp: InspectorController) -> some View {
        HStack(spacing: StudioStyle.Space.s) {
            Button("Save as Version…") { variantName = model.selectedScene.map { "\($0) version" } ?? "version"; savingVariant = true }
                .disabled(insp.editorJSON == nil)
                .help("Save this content as a named version (export it with --props)")
                .popover(isPresented: $savingVariant, arrowEdge: .bottom) { variantPopover(insp) }
            if insp.propsApplying { ProgressView().controlSize(.small) }
            else if insp.propsEdited { Text("Not applied yet").font(StudioStyle.Fonts.subheadline).foregroundStyle(.secondary) }
            Spacer(minLength: StudioStyle.Space.xs)
            Button("Revert") { insp.revertProps() }
                .disabled(!insp.propsEdited && insp.propsIssue == nil)
            Button("Apply") { Task { await insp.applyProps() } }
                .buttonStyle(.borderedProminent)
                .disabled(insp.editorJSON == nil || insp.propsApplying || !insp.propsEdited)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Apply to the film (⌘↩)")
        }
        .controlSize(.small)
        .padding(.horizontal, StudioStyle.Space.gutter)
        .padding(.vertical, StudioStyle.Space.s)
    }

    private func variantPopover(_ insp: InspectorController) -> some View {
        VStack(alignment: .leading, spacing: StudioStyle.Space.s) {
            Text("Save as Version").font(StudioStyle.Fonts.headline)
            TextField("Name", text: $variantName)
                .studioField()
                .frame(width: 240)
                .onSubmit(save)
            Text("Saved to .swift-render/props/\(model.selectedScene ?? "Scene")/\(InspectorController.variantFileName(variantName)).json")
                .font(StudioStyle.Fonts.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { savingVariant = false }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(InspectorController.variantFileName(variantName).isEmpty)
            }
        }
        .padding(StudioStyle.Space.l)
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
        if let doc = insp.propsDoc, case .object(let members) = doc {
            let scalars = members.filter { !$0.value.isContainer }
            let groups = members.filter { $0.value.isContainer }
            ScrollViewReader { proxy in
                Form {
                    if !scalars.isEmpty {
                        Section {
                            ForEach(scalars, id: \.key) { m in field(.root.appending(.key(m.key)), m.value) }
                        }
                    }
                    ForEach(groups, id: \.key) { m in
                        let path = PropsPath.root.appending(.key(m.key))
                        Section {
                            container(path, m.value, depth: 0)
                        } header: {
                            Text(KnobNames.humanize(m.key))
                        } footer: {
                            if case .array(let a) = m.value { listControls(path, count: a.count) }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .onChange(of: insp.issueRow) { _, p in if let p { withAnimation { proxy.scrollTo(p, anchor: .center) } } }
            }
        } else if insp.propsDoc != nil {
            StudioEmptyState(title: "Edit this one as JSON", symbol: StudioStyle.Symbol.content,
                             message: "This content isn't a set of named fields, so the form can't show it.")
        }
    }

    /// The children of an object or list, inside a section or a disclosure group.
    private func container(_ path: PropsPath, _ value: JSONValue, depth: Int) -> AnyView {
        switch value {
        case .object(let members):
            return AnyView(ForEach(members, id: \.key) { m in
                let p = path.appending(.key(m.key))
                if m.value.isContainer { disclosure(p, m.value, title: KnobNames.humanize(m.key), depth: depth + 1) }
                else { field(p, m.value) }
            })
        case .array(let items):
            return AnyView(ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let p = path.appending(.index(i))
                if item.isContainer {
                    disclosure(p, item, title: Self.itemTitle(item, index: i), depth: depth + 1)
                        .contextMenu { Button("Remove Item", role: .destructive) { insp.removeElement(p) } }
                } else {
                    field(p, item, label: nil)
                        .contextMenu { Button("Remove Item", role: .destructive) { insp.removeElement(p) } }
                }
            })
        default:
            return AnyView(field(path, value))
        }
    }

    private func disclosure(_ path: PropsPath, _ value: JSONValue, title: String, depth: Int) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { insp.propsExpanded.contains(path) || issueInside(path) },
                                            set: { open in
                                                if open != insp.propsExpanded.contains(path) { insp.toggleExpanded(path) }
                                            })) {
            container(path, value, depth: depth)
            if case .array(let a) = value { listControls(path, count: a.count) }
        } label: {
            Text(title).lineLimit(1)
        }
        .id(path)
    }

    private func issueInside(_ path: PropsPath) -> Bool {
        guard let p = insp.issueRow else { return false }
        return p == path || p.ancestors.contains(path)
    }

    /// + / − for a list: add a copy of the last item, remove the last one.
    private func listControls(_ path: PropsPath, count: Int) -> some View {
        HStack {
            Spacer()
            ControlGroup {
                Button { insp.appendElement(path) } label: { Image(systemName: "plus") }
                    .disabled(count == 0)
                    .help(count == 0 ? "Add the first item in JSON mode" : "Add an item (a copy of the last one)")
                Button { insp.removeElement(path.appending(.index(count - 1))) } label: { Image(systemName: "minus") }
                    .disabled(count == 0)
                    .help("Remove the last item")
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func field(_ path: PropsPath, _ value: JSONValue, label explicit: String?? = .none) -> some View {
        let label: String? = explicit ?? path.last.map {
            switch $0 { case .key(let k): return KnobNames.humanize(k); case .index(let i): return "Item \(i + 1)" }
        }
        let issue = path == insp.issueRow ? insp.propsIssue?.message : nil
        VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
            control(path, value, label: label ?? "")
            if let issue {
                Label(issue.prefix(1).uppercased() + issue.dropFirst(), systemImage: StudioStyle.Symbol.error)
                    .font(StudioStyle.Fonts.subheadline).foregroundStyle(StudioStyle.error)
            }
        }
        .id(path)
        .help(path.description)
    }

    @ViewBuilder
    private func control(_ path: PropsPath, _ value: JSONValue, label: String) -> some View {
        switch value {
        case .null:
            LabeledContent(label) { Text("Empty").foregroundStyle(.tertiary) }
        case .bool(let b):
            Toggle(label, isOn: Binding(get: { b }, set: { insp.setField(path, .bool($0)) }))
                .toggleStyle(StudioSwitchStyle())
        case .number(let lit):
            LabeledContent(label) {
                PropsNumberField(literal: lit) { insp.setField(path, .number($0)) }
            }
        case .string(let s):
            switch PropsFieldKind(value) {
            case .color:
                LabeledContent(label) {
                    ColorPicker("", selection: Binding(get: { KnobColorControl.color(s) },
                                                       set: { insp.setField(path, .string(KnobColorControl.hex($0))) }),
                                supportsOpacity: true)
                        .labelsHidden()
                        .help(s)
                }
            case .media:
                VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                    if !label.isEmpty { Text(label) }
                    HStack(spacing: StudioStyle.Space.xs) {
                        PropsTextField(text: s, code: true) { insp.setField(path, .string($0)) }
                        Button { pickMedia(path, current: s) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("Choose a file")
                    }
                }
            default:
                let long = s.count > 24 || s.contains("\n")
                if long || label.isEmpty {
                    VStack(alignment: .leading, spacing: StudioStyle.Space.xs) {
                        if !label.isEmpty { Text(label) }
                        PropsTextField(text: s, code: path.last == .key("source"), multiline: s.count > 40 || s.contains("\n")) {
                            insp.setField(path, .string($0))
                        }
                    }
                } else {
                    LabeledContent(label) {
                        PropsTextField(text: s) { insp.setField(path, .string($0)) }
                            .frame(maxWidth: 150)
                    }
                }
            }
        case .array, .object:
            EmptyView()
        }
    }

    /// An item's title: its first bit of text ("swift-render 0.10"), never its index.
    static func itemTitle(_ v: JSONValue, index: Int) -> String {
        if case .object(let members) = v {
            for key in ["title", "name", "label", "text", "value"] {
                if case .string(let s)? = members.first(where: { $0.key == key })?.value, !s.isEmpty { return s }
            }
            for m in members { if case .string(let s) = m.value, !s.isEmpty, PropsFieldKind(m.value) == .text { return s } }
        }
        return "Item \(index + 1)"
    }

    /// "features › Springs" for an issue path.
    static func title(for path: PropsPath) -> String {
        path.components.map { c -> String in
            switch c { case .key(let k): return KnobNames.humanize(k); case .index(let i): return "item \(i + 1)" }
        }.joined(separator: " › ")
    }

    /// Files inside the project are stored relative to its root, as scenes resolve them.
    private func pickMedia(_ path: PropsPath, current: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        let cur = URL(fileURLWithPath: current, relativeTo: model.project.root)
        panel.directoryURL = cur.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = model.project.root.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        insp.setField(path, .string(p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p))
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
            .font(StudioStyle.Fonts.callout.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .focused($focused)
            .studioField(focused: focused, invalid: invalid)
            .frame(maxWidth: 96)
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onChange(of: literal, initial: true) { _, l in if !focused { text = l; invalid = false } }
            .help(invalid ? "That isn't a number" : "")
    }

    private func apply() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != literal else { invalid = false; return }
        if JSONValue.isNumberLiteral(t) { invalid = false; commit(t) }
        else if let d = KnobCoercion.parseNumber(t), let lit = JSONValue.numberLiteral(d) { invalid = false; commit(lit) }
        else { invalid = true }
    }
}

/// Text field that writes through on every edit (content applies on ⌘↩, not per keystroke).
struct PropsTextField: View {
    var text: String
    var code = false
    var multiline = false
    var commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, axis: multiline ? .vertical : .horizontal)
            .font(code ? StudioStyle.Fonts.codeSmall : StudioStyle.Fonts.callout)
            .lineLimit(multiline ? 1...6 : 1...1)
            .labelsHidden()
            .focused($focused)
            .studioField(focused: focused)
            .onChange(of: text, initial: true) { _, t in if !focused { draft = t } }
            .onChange(of: draft) { _, d in if focused, d != text { commit(d) } }   // typing only
    }
}
