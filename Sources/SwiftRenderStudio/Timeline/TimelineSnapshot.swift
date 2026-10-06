import Foundation
import SwiftRenderKit

// MARK: - Timeline snapshot options
//
// `--snapshot` extras for showing timeline states headlessly (read from argv here
// so LaunchOptions stays untouched; it already skips unknown `--flag value` pairs):
//
//   --wait-audio            wait for the score WAV + loudness, decode the waveform
//   --timeline-zoom <pps>   points per second (fit … 20 px/frame)
//   --timeline-start <s>    left edge, seconds
//   --inout <a>,<b>         set in/out
//   --select-clip <n|id>    select the n-th clip (by start) or a clip id
//   --hover <x>,<y>         hover a lanes-column point (card + highlight)
//
// The timeline fits its lanes unless `layout.timelineHeightManual` is set, which the
// argument domain overrides without writing: `-layout.timelineHeightManual 420`.

@MainActor
enum TimelineSnapshot {
    static let hoverNotification = Notification.Name("SwiftRenderStudio.timelineHover")

    struct Options: Equatable {
        var waitAudio = false
        var zoom: Double?
        var start: Double?
        var inOut: ClosedRange<Double>?
        var selectClip: String?
        var hover: CGPoint?

        static func parse(_ argv: [String]) -> Options {
            var o = Options()
            var i = 0
            func pair(_ s: String?) -> (Double, Double)? {
                let parts = (s ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
            while i < argv.count {
                let v = i + 1 < argv.count ? argv[i + 1] : nil
                switch argv[i] {
                case "--wait-audio": o.waitAudio = true; i += 1; continue
                case "--timeline-zoom": o.zoom = v.flatMap(Double.init)
                case "--timeline-start": o.start = v.flatMap(Double.init)
                case "--inout": o.inOut = pair(v).flatMap { $0.0 <= $0.1 ? $0.0...$0.1 : nil }
                case "--select-clip": o.selectClip = v
                case "--hover": o.hover = pair(v).map { CGPoint(x: $0.0, y: $0.1) }
                default: i += 1; continue
                }
                i += 2
            }
            return o
        }
    }

    /// Apply the options to a started model (called by SnapshotRunner before capture).
    static func prepare(_ model: ProjectModel, argv: [String] = CommandLine.arguments) async {
        let o = Options.parse(argv)
        if o.waitAudio, let scene = model.selectedScene,
           model.scenes.first(where: { $0.name == scene })?.hasSoundtrack ?? true {
            let deadline = Date().addingTimeInterval(180)
            while model.info?.audioPath == nil || (model.info?.loudness.isEmpty ?? true), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let path = model.info?.audioPath { await AudioOverviewCache.shared.load(path) }
            // Captions follow the audio event in a separate `info`.
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let io = o.inOut { model.playback.setInOut(io) }
        if let sel = o.selectClip, let clips = model.info?.clips.sorted(by: { ($0.start, $0.depth) < ($1.start, $1.depth) }) {
            model.ui.selectedClipID = Int(sel).flatMap { $0 >= 0 && $0 < clips.count ? clips[$0].id : nil } ?? sel
        }
        if o.zoom != nil || o.start != nil {
            var v = model.ui.viewport
            if let z = o.zoom { v.zoom(to: z, around: 0) }
            if let s = o.start { v.start = s; v.clamp() }
            model.ui.viewport = v
        }
        if let p = o.hover {
            // Let the zoomed lanes lay out first; the hover hit-tests against them.
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: hoverNotification, object: p)
        }
    }
}
