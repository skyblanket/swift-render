import Foundation

// MARK: - Render presets
//
// Each preset is a set of `render` flags for the project CLI plus what Studio needs to
// describe and validate it. Sizes come from the engine's own rules: `--scale 2` makes
// Recorder encode `size × scale` (3840×2160), `--preview` is half size at 30 fps, and
// `--width/--height` set the canvas outright (App Store previews).

enum RenderPreset: String, CaseIterable, Identifiable, Sendable {
    case master1080p60, uhd4k, vertical9x16, square, preview, appStorePortrait, appStoreLandscape, gif
    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable {
        case master = "Master", social = "Social", appStore = "App Store", draft = "Draft"
        /// Column header on the Export sheet.
        var title: String { self == .master ? "Best Quality" : rawValue }
    }

    var group: Group {
        switch self {
        case .master1080p60, .uhd4k: return .master
        case .vertical9x16, .square: return .social
        case .appStorePortrait, .appStoreLandscape: return .appStore
        case .preview, .gif: return .draft
        }
    }

    var title: String {
        switch self {
        case .master1080p60: return "Master 1080p60"
        case .uhd4k: return "4K UHD"
        case .vertical9x16: return "Vertical 9:16"
        case .square: return "Square 1:1"
        case .preview: return "Preview"
        case .appStorePortrait: return "App Preview Portrait"
        case .appStoreLandscape: return "App Preview Landscape"
        case .gif: return "GIF"
        }
    }

    /// Name on the sheet's preset tile (the column header gives the group).
    var tileTitle: String {
        switch self {
        case .master1080p60: return "1080p60"
        case .uhd4k: return "4K UHD"
        case .vertical9x16: return "Vertical 9:16"
        case .square: return "Square 1:1"
        case .preview: return "Preview"
        case .appStorePortrait: return "Portrait"
        case .appStoreLandscape: return "Landscape"
        case .gif: return "GIF"
        }
    }

    /// "1920×1080" (no digit grouping).
    var sizeLabel: String { "\(String(pixelSize.width))×\(String(pixelSize.height))" }

    /// Short name used in output file names.
    var fileTag: String {
        switch self {
        case .master1080p60: return "1080p60"
        case .uhd4k: return "4k"
        case .vertical9x16: return "9x16"
        case .square: return "1x1"
        case .preview: return "preview"
        case .appStorePortrait: return "appstore-portrait"
        case .appStoreLandscape: return "appstore-landscape"
        case .gif: return "gif"
        }
    }

    /// Encoded pixel size.
    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .master1080p60: return (1920, 1080)
        case .uhd4k: return (3840, 2160)
        case .vertical9x16: return (1080, 1920)
        case .square: return (1080, 1080)
        case .preview: return (960, 540)
        case .appStorePortrait: return (886, 1920)
        case .appStoreLandscape: return (1920, 886)
        case .gif: return (720, 405)
        }
    }

    var fps: Int {
        switch self {
        case .master1080p60, .uhd4k, .vertical9x16, .square: return 60
        case .preview, .appStorePortrait, .appStoreLandscape: return 30
        case .gif: return 15
        }
    }

    /// The canvas the scene lays out in differs from the 16:9 it was authored at.
    var changesAspect: Bool {
        let (w, h) = pixelSize
        return abs(Double(w) / Double(h) - 16.0 / 9.0) > 0.02
    }

    /// App Store Connect rejects app previews outside 15–30 s.
    var durationLimit: ClosedRange<Double>? {
        group == .appStore ? 15...30 : nil
    }

    var isGIF: Bool { self == .gif }
    var fileExtension: String { isGIF ? "gif" : "mp4" }

    /// The CLI picks the bitrate from the pixel count (`Recorder.Config.defaultBitrate`).
    var megabitsPerSecond: Int? {
        guard !isGIF else { return nil }
        let px = pixelSize.width * pixelSize.height
        switch px {
        case 0...921_600: return 6
        case 921_601...2_073_600: return 12
        case 2_073_601...3_686_400: return 24
        default: return 35
        }
    }

    var summary: String {
        let codec = isGIF ? "GIF (ffmpeg)" : "H.264 \(megabitsPerSecond ?? 0) Mb/s"
        return "\(sizeLabel) · \(fps) fps · \(codec)"
    }

    var symbol: String {
        switch self {
        case .master1080p60: return "film"
        case .uhd4k: return "4k.tv"
        case .vertical9x16: return "rectangle.portrait"
        case .square: return "square"
        case .preview: return "bolt"
        case .appStorePortrait: return "iphone"
        case .appStoreLandscape: return "iphone.landscape"
        case .gif: return "photo.stack"
        }
    }

    /// Optimized (release) builds by default for deliverables; debug is fine for drafts.
    var prefersRelease: Bool { group == .master || group == .appStore }

    /// `render` arguments (without `--progress`, range, knobs or props). For a GIF, `out`
    /// is the intermediate MP4 that ffmpeg converts.
    func args(scene: String, out: URL) -> [String] {
        var a = ["render", scene, "--out", out.path]
        switch self {
        case .master1080p60: a += ["--fps", "60"]
        case .uhd4k: a += ["--fps", "60", "--scale", "2"]
        case .vertical9x16: a += ["--fps", "60", "--aspect", "9:16"]
        case .square: a += ["--fps", "60", "--aspect", "1:1"]
        case .preview: a += ["--preview"]
        case .appStorePortrait: a += ["--fps", "30", "--width", "886", "--height", "1920"]
        case .appStoreLandscape: a += ["--fps", "30", "--width", "1920", "--height", "886"]
        // Grain dithers into noisy, huge palettes: GIFs render clean, at half size, 15 fps.
        case .gif: a += ["--fps", "15", "--scale", "0.5", "--no-postfx"]
        }
        return a
    }

    /// ffmpeg arguments turning the intermediate MP4 into a looping GIF (one-pass palette).
    static func gifArgs(input: URL, output: URL) -> [String] {
        let (w, _) = RenderPreset.gif.pixelSize
        return ["-y", "-loglevel", "error", "-i", input.path, "-filter_complex",
                "[0:v]scale=\(w):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                "-loop", "0", output.path]
    }

    /// ffmpeg arguments muxing the score's `[start, end)` slice into a silent range render.
    static func muxArgs(video: URL, audio: URL, start: Double, end: Double, output: URL) -> [String] {
        ["-y", "-loglevel", "error", "-i", video.path,
         "-ss", String(format: "%.4f", start), "-t", String(format: "%.4f", end - start), "-i", audio.path,
         "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-shortest",
         "-movflags", "+faststart", output.path]
    }

    /// Why this preset can't render `duration` seconds, or nil when it can.
    func durationProblem(_ duration: Double) -> String? {
        guard let limit = durationLimit else { return nil }
        // Frame rounding: 30.00 s at 30 fps is 900 frames, still in bounds.
        let d = (duration * Double(fps)).rounded() / Double(fps)
        if d < limit.lowerBound || d > limit.upperBound {
            return String(format: "App previews must be %.0f–%.0f s; this is %.2f s. Set In/Out (I, O) to a %.0f–%.0f s range.",
                          limit.lowerBound, limit.upperBound, d, limit.lowerBound, limit.upperBound)
        }
        return nil
    }

    static var remembered: RenderPreset {
        get { UserDefaults.standard.string(forKey: "render.lastPreset").flatMap(RenderPreset.init) ?? .master1080p60 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "render.lastPreset") }
    }
}

enum BuildChoice: String, CaseIterable, Sendable { case optimized, currentDebug }
enum KnobChoice: String, CaseIterable, Sendable { case saveToFile, useLive }
