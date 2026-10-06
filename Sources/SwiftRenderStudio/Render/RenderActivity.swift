import SwiftUI

// MARK: - Render activity   // S9
//
// Toolbar button + popover listing jobs. S9 adds progress bars with fps/ETA, Reveal
// in Finder, Open, and Attach to comment.

struct RenderActivityButton: View {
    @Bindable var model: ProjectModel

    var body: some View {
        Button { model.ui.showRenderActivity.toggle() } label: {
            Image(systemName: model.renders.active == nil ? "square.stack.3d.down.right" : "square.stack.3d.down.right.fill")
        }
        .help("Render activity")
        .popover(isPresented: $model.ui.showRenderActivity, arrowEdge: .bottom) {
            RenderActivityList(model: model)
        }
    }
}

struct RenderActivityList: View {
    @Bindable var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Renders").font(.headline)
            if model.renders.jobs.isEmpty {
                Text("No renders yet — ⌘R renders with the last preset.").foregroundStyle(.secondary)
            }
            ForEach(model.renders.jobs) { job in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(job.scene) · \(job.preset.title)")
                        Text(status(job.state)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.renders.cancel(job.id) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func status(_ s: RenderJob.State) -> String {
        switch s {
        case .queued: return "Queued (render queue lands in S9)"
        case .building: return "Building release…"
        case .rendering(let d, let t, let fps): return "\(d)/\(t) · \(Int(fps)) fps"
        case .finished(let secs): return String(format: "Done in %.1fs", secs)
        case .failed(let why): return "Failed: \(why)"
        case .cancelled: return "Cancelled"
        }
    }
}
