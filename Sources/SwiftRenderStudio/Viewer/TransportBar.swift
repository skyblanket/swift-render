import SwiftUI

// MARK: - Transport
//
// |◀  ◀◀  ▶  ▶▶  ▶|   00:12.40 / 01:33.00   f744@60   [I 00:10.00 → O 00:20.00]  ⟲  ♪

struct TransportBar: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let p = model.playback
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                transportButton("backward.end.fill", help: "Start (Home)") { model.perform(.home) }
                transportButton("backward.fill", help: "Reverse shuttle (J)") { model.perform(.shuttle(.j)) }
                transportButton(p.isPlaying ? "pause.fill" : "play.fill", help: "Play/Pause (Space)", prominent: true) {
                    model.perform(.playPause)
                }
                transportButton("forward.fill", help: "Forward shuttle (L)") { model.perform(.shuttle(.l)) }
                transportButton("forward.end.fill", help: "End (End)") { model.perform(.end) }
            }

            TransportTimecode(engine: p)

            if p.rate != 1 && p.isPlaying {
                StudioBadge(text: String(format: "%@%g×", p.rate < 0 ? "−" : "", abs(p.rate)), color: StudioStyle.accent)
            }

            inOutLabel

            Spacer(minLength: 8)

            Toggle(isOn: Binding(get: { p.loop }, set: { _ in model.perform(.loopInOut) })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Loop in→out (/)")

            Image(systemName: p.audio.hasAudio ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(p.audio.hasAudio ? Color.secondary : Color.secondary.opacity(0.5))
                .help(p.audio.hasAudio ? "Score audio" : "No audio for this scene yet")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    @ViewBuilder private var inOutLabel: some View {
        let p = model.playback
        if let io = p.inOut {
            HStack(spacing: 4) {
                Text("I").fontWeight(.bold)
                Text(StudioStyle.timecode(io.lowerBound))
                Image(systemName: "arrow.right").imageScale(.small)
                Text("O").fontWeight(.bold)
                Text(StudioStyle.timecode(io.upperBound))
            }
            .font(StudioStyle.monoSmall)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(StudioStyle.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(StudioStyle.accent)
            .help("In/out (I / O, ⌥X clears)")
        } else {
            Text("No in/out — I · O")
                .font(StudioStyle.monoSmall)
                .foregroundStyle(.tertiary)
        }
    }

    private func transportButton(_ symbol: String, help: String, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .frame(width: prominent ? 30 : 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(prominent ? .primary : .secondary)
        .help(help)
    }
}

/// Reads `t` (60 Hz while playing) — isolated from the rest of the bar.
struct TransportTimecode: View {
    var engine: PlaybackEngine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(StudioStyle.timecode(engine.t))
                .font(StudioStyle.timecodeLarge)
                .foregroundStyle(.primary)
            Text("/ \(StudioStyle.timecode(engine.duration))")
                .font(StudioStyle.mono)
                .foregroundStyle(.secondary)
            Text("f\(frameIndex(engine.t, fps: engine.fps))@\(engine.fps)")
                .font(StudioStyle.monoSmall)
                .foregroundStyle(.tertiary)
        }
        .monospacedDigit()
    }
}
