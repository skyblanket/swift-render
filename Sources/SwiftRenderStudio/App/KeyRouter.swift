import AppKit

// MARK: - Key router
//
// Unmodified editing keys (Space, J/K/L, arrows, I/O, C, R, G, [ ], \, /, ⌫, Esc) go
// through a local NSEvent monitor instead of menu key equivalents, and are passed
// through untouched whenever a text field is being edited — typing "jkl c io" in
// the comment composer must never seek. Keys with ⌘/⌃ belong to StudioCommands.

@MainActor
final class KeyRouter {
    /// A key press, decoupled from NSEvent so routing is unit-testable.
    struct Stroke: Equatable {
        var chars: String           // charactersIgnoringModifiers (shift still applies)
        var keyCode: UInt16
        var shift = false
        var option = false
        var command = false
        var control = false

        init(chars: String, keyCode: UInt16 = 0, shift: Bool = false, option: Bool = false,
             command: Bool = false, control: Bool = false) {
            self.chars = chars; self.keyCode = keyCode; self.shift = shift; self.option = option
            self.command = command; self.control = control
        }

        init(_ e: NSEvent) {
            let f = e.modifierFlags
            self.init(chars: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, shift: f.contains(.shift),
                      option: f.contains(.option), command: f.contains(.command), control: f.contains(.control))
        }
    }

    enum KeyCode {
        static let space: UInt16 = 49, escape: UInt16 = 53
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let home: UInt16 = 115, end: UInt16 = 119
        static let k: UInt16 = 40
        static let delete: UInt16 = 51, forwardDelete: UInt16 = 117
    }

    private weak var model: ProjectModel?
    private weak var window: NSWindow?
    private var monitor: Any?
    /// K held: J/L step single frames.
    private(set) var kHeld = false

    init(model: ProjectModel?) { self.model = model }

    func install(window: NSWindow?) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            let consumed = MainActor.assumeIsolated { self?.consumes(e) ?? false }
            return consumed ? nil : e
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// True when the event was turned into an action.
    private func consumes(_ e: NSEvent) -> Bool {
        guard let window, e.window === window, let model else { return false }
        let s = Stroke(e)
        if e.type == .keyUp {
            if s.keyCode == KeyCode.k || s.chars.lowercased() == "k" { kHeld = false }
            return false
        }
        // Sheets/popovers own their keys.
        if window.attachedSheet != nil { return false }
        guard let action = action(for: s, textEditing: Self.isTextEditing(window), isRepeat: e.isARepeat) else { return false }
        model.perform(action)
        return true
    }

    /// A field editor (NSTextView) or any NSText is first responder.
    static func isTextEditing(_ window: NSWindow?) -> Bool {
        guard let r = (NSApp.keyWindow ?? window)?.firstResponder else { return false }
        return r is NSText
    }

    /// Maps a key-down to an action; nil passes the event through to AppKit.
    func action(for s: Stroke, textEditing: Bool, isRepeat: Bool = false) -> StudioAction? {
        if textEditing || s.command || s.control { return nil }
        switch s.keyCode {
        case KeyCode.space: return s.option || s.shift ? nil : .playPause
        case KeyCode.escape: return .cancel
        case KeyCode.left: return s.shift ? .stepSeconds(-1) : .stepFrames(-1)
        case KeyCode.right: return s.shift ? .stepSeconds(1) : .stepFrames(1)
        case KeyCode.up: return .jumpEdit(next: false)
        case KeyCode.down: return .jumpEdit(next: true)
        case KeyCode.home: return .home
        case KeyCode.end: return .end
        case KeyCode.delete, KeyCode.forwardDelete: return s.option || s.shift ? nil : .deleteSelection
        default: break
        }
        if s.option {
            // ⌥X clears in/out (charactersIgnoringModifiers keeps it "x").
            return s.chars.lowercased() == "x" ? .clearInOut : nil
        }
        switch s.chars {
        case "j": return kHeld ? .stepFrames(-1) : .shuttle(.j)
        case "l": return kHeld ? .stepFrames(1) : .shuttle(.l)
        case "k":
            if isRepeat { return nil }
            kHeld = true
            return .shuttle(.k)
        case "i": return .setIn
        case "I": return .goIn
        case "o": return .setOut
        case "O": return .goOut
        case "/": return .loopInOut
        case "c": return .newComment
        case "r": return .armRegion
        case "[": return .selectComment(next: false)
        case "]": return .selectComment(next: true)
        case "\\": return .toggleCompare
        case "|": return .cycleCompare
        case "g": return .cycleGuides
        case "Z": return .timelineZoomFit
        default: return nil
        }
    }

    /// Test hook: K released.
    func releaseK() { kHeld = false }
}
