import AppKit
import SwiftRenderKit

// MARK: - Open source in the user's editor

enum EditorChoice: String, CaseIterable, Identifiable, Sendable {
    case xcode, cursor, vscode, zed, sublime, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: return "Xcode"
        case .cursor: return "Cursor"
        case .vscode: return "Visual Studio Code"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .system: return "Default app"
        }
    }
}

enum SourceOpener {
    static let defaultsKey = "editor"

    static var preferred: EditorChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(EditorChoice.init) ?? .xcode
    }

    /// The command line that opens `file` at `line`/`column`; nil for `.system`.
    static func command(file: String, line: Int, column: Int = 0, with editor: EditorChoice) -> (tool: String, args: [String])? {
        let col = max(1, column)
        switch editor {
        case .xcode: return ("xed", ["-l", String(max(1, line)), file])
        case .cursor: return ("cursor", ["-g", "\(file):\(line):\(col)"])
        case .vscode: return ("code", ["-g", "\(file):\(line):\(col)"])
        case .zed: return ("zed", ["\(file):\(line):\(col)"])
        case .sublime: return ("subl", ["\(file):\(line):\(col)"])
        case .system: return nil
        }
    }

    static func open(_ loc: SourceLocation, column: Int = 0, with editor: EditorChoice = preferred) {
        open(file: loc.file, line: loc.line, column: column, with: editor)
    }

    static func open(_ d: CompilerDiagnostic, with editor: EditorChoice = preferred) {
        open(file: d.file, line: d.line, column: d.column, with: editor)
    }

    /// Falls back to `NSWorkspace.open` when the editor's CLI isn't installed or fails.
    static func open(file: String, line: Int, column: Int = 0, with editor: EditorChoice = preferred) {
        let url = URL(fileURLWithPath: file)
        guard let cmd = command(file: file, line: line, column: column, with: editor) else {
            NSWorkspace.shared.open(url); return
        }
        Task.detached {
            let exe = cmd.tool == "xed" ? URL(fileURLWithPath: "/usr/bin/xed") : await ToolPaths.resolve(cmd.tool)
            guard let exe, FileManager.default.isExecutableFile(atPath: exe.path) else {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
                return
            }
            let ok = (try? ProcessRunner.run(exe.path, cmd.args, environment: ToolPaths.environment))?.status == 0
            if !ok { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        }
    }

    /// Reveal a file (renders, attachments) in Finder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
