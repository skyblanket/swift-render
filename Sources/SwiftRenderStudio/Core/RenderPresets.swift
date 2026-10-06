import Foundation

// MARK: - Render presets   // S9
//
// To finish (studio-ux §1.8/§2.6): 4K needs Recorder `outputSize`; 9:16 stays disabled
// unless the scene declares aspect formats; `--progress json`, `--knobs`.

enum RenderPreset: String, CaseIterable, Identifiable, Sendable {
    case master1080p60, uhd4k, vertical9x16, preview
    var id: String { rawValue }

    var title: String {
        switch self {
        case .master1080p60: return "Master 1080p60"
        case .uhd4k: return "4K UHD"
        case .vertical9x16: return "Vertical 9:16"
        case .preview: return "Preview"
        }
    }

    var summary: String {
        switch self {
        case .master1080p60: return "1920×1080 · 60 fps · H.264"
        case .uhd4k: return "3840×2160 · 60 fps · H.264"
        case .vertical9x16: return "1080×1920 · 60 fps · H.264"
        case .preview: return "960×540 · 30 fps · H.264"
        }
    }

    /// Optimized (release) builds by default for deliverables.
    var prefersRelease: Bool { self == .master1080p60 || self == .uhd4k }

    func args(scene: String, out: URL) -> [String] {
        var a = ["render", scene, "--out", out.path]
        switch self {
        case .master1080p60: a += ["--fps", "60"]
        case .uhd4k: a += ["--fps", "60", "--scale", "2"]
        case .vertical9x16: a += ["--fps", "60", "--aspect", "9:16"]
        case .preview: a += ["--preview"]
        }
        return a
    }
}

enum BuildChoice: String, CaseIterable, Sendable { case optimized, currentDebug }
enum KnobChoice: String, CaseIterable, Sendable { case saveToFile, useLive }
