import AppKit
import SwiftUI

// MARK: - Menu model
//
// Every right-click menu in Studio is a `[StudioMenuEntry]` built by one function per
// thing (a comment, a scene, an export, a clip…), so the list row, the viewer pin and the
// timeline marker of the same comment always offer the same commands in the same order.
// One builder feeds three surfaces:
//
//   .studioContextMenu(entries)   the right-click menu, plus the same commands as
//                                 VoiceOver actions on the element
//   StudioMenuContent(entries)    the items inside any Menu / .contextMenu
//   MenuPreview(entries)          a drawing of the menu for `--context-menu` snapshots
//
// Order follows the Mac convention: open/go actions, then state changes, then the
// file/clipboard commands, and anything destructive last, after a separator. A
// destructive item that asks first ends in "…".

/// A shortcut shown next to a menu item. Shown only: the real key lives in the menu bar or
/// `KeyRouter`, so a hint here never adds a second binding.
struct MenuShortcut: Equatable, Sendable {
    var key: KeyEquivalent
    var modifiers: EventModifiers = []

    /// "⌘C", "⌫" — what the snapshot preview draws.
    var glyphs: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .delete: s += "⌫"
        case .deleteForward: s += "⌦"
        case .return: s += "↩"
        case .escape: s += "⎋"
        case .space: s += "Space"
        default: s += String(key.character).uppercased()
        }
        return s
    }

    static let copy = MenuShortcut(key: "c", modifiers: .command)
    static let delete = MenuShortcut(key: .delete)
    static let open = MenuShortcut(key: .return)
}

struct StudioMenuItem: Identifiable {
    var title: String
    var symbol: String?
    var shortcut: MenuShortcut?
    var destructive = false
    var enabled = true
    /// Non-nil for an on/off item (drawn with a checkmark when on).
    var checked: Bool?
    var help: String?
    var action: @MainActor () -> Void
    var id: String { title }
}

enum StudioMenuEntry: Identifiable {
    case item(StudioMenuItem)
    case divider(Int)

    var id: String {
        switch self {
        case .item(let i): return i.title
        case .divider(let n): return "—\(n)"
        }
    }

    var item: StudioMenuItem? {
        if case .item(let i) = self { return i }
        return nil
    }
}

/// Builds entries with separators that never double up or dangle.
struct StudioMenuBuilder {
    private(set) var entries: [StudioMenuEntry] = []
    private var dividers = 0

    mutating func add(_ title: String, symbol: String? = nil, shortcut: MenuShortcut? = nil, destructive: Bool = false,
                      enabled: Bool = true, checked: Bool? = nil, help: String? = nil,
                      _ action: @escaping @MainActor () -> Void) {
        entries.append(.item(StudioMenuItem(title: title, symbol: symbol, shortcut: shortcut, destructive: destructive,
                                            enabled: enabled, checked: checked, help: help, action: action)))
    }

    mutating func divider() {
        guard let last = entries.last, case .item = last else { return }
        dividers += 1
        entries.append(.divider(dividers))
    }

    /// The entries, without a trailing separator.
    var built: [StudioMenuEntry] {
        if let last = entries.last, case .divider = last { return Array(entries.dropLast()) }
        return entries
    }
}

extension Array where Element == StudioMenuEntry {
    /// Item titles with "—" for separators: what tests compare.
    var outline: [String] {
        map { e in
            switch e {
            case .divider: return "—"
            case .item(let i): return i.title + (i.shortcut.map { " \($0.glyphs)" } ?? "") + (i.enabled ? "" : " (off)")
            }
        }
    }

    func item(_ title: String) -> StudioMenuItem? {
        lazy.compactMap(\.item).first { $0.title == title }
    }
}

/// The items of a menu, for `.contextMenu { }` and `Menu { }`.
extension Array where Element == StudioMenuEntry {
    /// Splits off the trailing destructive group (after its separator), so a host menu
    /// that appends its own commands can still put the destructive ones last.
    var splitDestructive: (head: [StudioMenuEntry], destructive: [StudioMenuEntry]) {
        var head = self, tail: [StudioMenuEntry] = []
        while let last = head.last, last.item?.destructive == true {
            tail.insert(last, at: 0)
            head.removeLast()
        }
        while let last = head.last, case .divider = last { head.removeLast() }
        return (head, tail)
    }
}

struct StudioMenuContent: View {
    var entries: [StudioMenuEntry]

    var body: some View {
        ForEach(entries) { e in
            switch e {
            case .divider:
                Divider()
            case .item(let i):
                if let on = i.checked {
                    Toggle(i.title, isOn: Binding(get: { on }, set: { _ in i.action() }))
                        .disabled(!i.enabled)
                } else {
                    Button(role: i.destructive ? .destructive : nil) { i.action() } label: {
                        if let s = i.symbol { Label(i.title, systemImage: s) } else { Text(i.title) }
                    }
                    .keyboardShortcut(i.shortcut.map { KeyboardShortcut($0.key, modifiers: $0.modifiers) })
                    .disabled(!i.enabled)
                    .help(i.help ?? "")
                }
            }
        }
    }
}

extension View {
    /// The right-click menu, and the same commands as VoiceOver actions on this element.
    func studioContextMenu(_ entries: [StudioMenuEntry]) -> some View {
        contextMenu { StudioMenuContent(entries: entries) }
            .studioAccessibilityActions(entries)
    }

    /// The menu's enabled commands as VoiceOver actions (VO-⌘-Space lists them).
    func studioAccessibilityActions(_ entries: [StudioMenuEntry]) -> some View {
        accessibilityActions {
            ForEach(entries.compactMap(\.item).filter(\.enabled)) { i in
                Button(i.title) { i.action() }
            }
        }
    }
}

/// A drawing of a menu (the system menu can't be captured offscreen): the same entries,
/// laid out like an AppKit menu, for `--context-menu` snapshots.
struct MenuPreview: View {
    var entries: [StudioMenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { e in
                switch e {
                case .divider:
                    Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
                case .item(let i):
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            .opacity(i.checked == true ? 1 : 0)
                            .frame(width: 12)
                        Group {
                            if let s = i.symbol { Image(systemName: s).frame(width: 16) } else { Color.clear.frame(width: 16, height: 1) }
                        }
                        Text(i.title)
                        Spacer(minLength: 24)
                        if let k = i.shortcut { Text(k.glyphs).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(i.enabled ? (i.destructive ? AnyShapeStyle(StudioStyle.error) : AnyShapeStyle(.primary))
                                               : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 220)
        .fixedSize()
    }
}
