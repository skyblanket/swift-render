import Foundation
import Observation
import SwiftRenderKit

// MARK: - Render queue   // S9
//
// To implement: one job at a time; optional `swift build -c release --scratch-path
// .build/studio`; `<bin>/<p> render … --progress json` with progress/ETA parsing;
// cancel = SIGINT, SIGTERM after 2 s, then delete the partial file.

struct RenderJob: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case building
        case rendering(done: Int, total: Int, fps: Double)
        case finished(seconds: Double)
        case failed(String)
        case cancelled
    }
    let id: UUID
    var scene: String
    var preset: RenderPreset
    var range: ClosedRange<Double>?
    var build: BuildChoice
    var knobs: KnobChoice
    var output: URL
    var state: State = .queued
}

@MainActor @Observable
final class RenderQueue {
    let project: Project
    var jobs: [RenderJob] = []
    /// Remembered for ⌘R.
    var lastPreset: RenderPreset = .master1080p60

    init(project: Project) { self.project = project }

    var active: RenderJob? {
        jobs.first {
            switch $0.state {
            case .building, .rendering: return true
            default: return false
            }
        }
    }

    static func defaultOutput(project: Project, scene: String, preset: RenderPreset, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return project.rendersDir.appendingPathComponent("\(scene)-\(preset.rawValue)-\(f.string(from: date)).mp4")
    }

    // S9: run the job.
    func enqueue(scene: String, preset: RenderPreset, range: ClosedRange<Double>?, build: BuildChoice, knobs: KnobChoice) {
        lastPreset = preset
        jobs.append(RenderJob(id: UUID(), scene: scene, preset: preset, range: range, build: build, knobs: knobs,
                              output: Self.defaultOutput(project: project, scene: scene, preset: preset)))
    }

    func cancel(_ id: RenderJob.ID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .cancelled
    }

    /// Finished renders on disk (sidebar).
    func recentOutputs(limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: project.rendersDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(limit).map { $0 }
    }
}
