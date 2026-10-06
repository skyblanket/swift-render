import SwiftUI

// MARK: - Agent panel   // S8
//
// Shell: header (status, run, cost, Stop) + transcript rows. S8 adds comment chips
// linking to threads, diff stats per file, Revert run, and live elapsed time.

struct AgentPanel: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let agent = model.agent
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("Agent").font(.system(size: 11, weight: .semibold))
                if let run = agent.currentRun {
                    Text("· run \(agent.runs.count)").foregroundStyle(.secondary)
                    if !run.commentIDs.isEmpty {
                        Text("· working on \(run.commentIDs.map { String($0.prefix(5)) }.joined(separator: " "))")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let cost = run.costUSD { Text(String(format: "· $%.2f", cost)).foregroundStyle(.secondary) }
                } else {
                    Text("· idle").foregroundStyle(.secondary)
                }
                Spacer()
                if agent.isRunning {
                    Button { model.perform(.stop) } label: { Label("Stop", systemImage: "stop.fill") }
                        .controlSize(.small)
                }
                Button { model.ui.showAgentPanel = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide agent panel (⌘⌥J)")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.bar)
            Divider()
            if agent.transcript.isEmpty {
                HStack(spacing: 6) {
                    Text("No agent run yet.").foregroundStyle(.secondary)
                    Text("Select comments and press ⌘⇧A to ask Claude to fix them.").foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(agent.transcript) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.title).font(.system(size: 11, weight: row.kind == .tool ? .semibold : .regular))
                                    .foregroundStyle(row.kind == .error ? StudioStyle.bad : .primary)
                                    .frame(width: row.kind == .tool ? 60 : nil, alignment: .leading)
                                Text(row.detail).font(StudioStyle.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(StudioStyle.laneBackground)
    }
}
