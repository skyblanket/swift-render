import SwiftUI

// MARK: - Transport
//
//   00:12:24 / 01:33:00        |◀  ◀◀  ▶  ▶▶  ▶|        [In 0:10 → Out 0:20]  ⟲  ♪
//
// The large timecode (m:ss.hh, the same clock as the ruler) is the typographic anchor; the play cluster sits centered
// under the picture. Frame numbers live in the timecode's tooltip.

struct TransportBar: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let p = model.playback
        ZStack {
            HStack(spacing: StudioStyle.Space.m) {
                TransportTimecode(engine: p)
                Spacer(minLength: StudioStyle.Space.s)
                if p.rate != 1 && p.isPlaying {
                    Text(String(format: "%@%g×", p.rate < 0 ? "−" : "", abs(p.rate)))
                        .font(StudioStyle.Fonts.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                inOutChip
                Toggle(isOn: Binding(get: { p.loop }, set: { _ in model.perform(.loopInOut) })) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(p.inOut == nil ? "Loop (/). Press I and O to set a range." : "Loop the range (/)")
                Image(systemName: p.audio.hasAudio ? "speaker.wave.2" : "speaker.slash")
                    .foregroundStyle(p.audio.hasAudio ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .help(p.audio.hasAudio ? "Plays the film's sound" : "No sound yet")
            }
            HStack(spacing: StudioStyle.Space.xs) {
                transportButton("backward.end.fill", help: "Go to Start (Home)") { model.perform(.home) }
                transportButton("backward.fill", help: "Play Backward (J)") { model.perform(.shuttle(.j)) }
                transportButton(p.isPlaying ? "pause.fill" : "play.fill", help: "Play or Pause (Space)", prominent: true) {
                    model.perform(.playPause)
                }
                transportButton("forward.fill", help: "Play Forward (L)") { model.perform(.shuttle(.l)) }
                transportButton("forward.end.fill", help: "Go to End (End)") { model.perform(.end) }
            }
        }
        .font(StudioStyle.Fonts.body)
        .padding(.horizontal, StudioStyle.Space.l)
        .frame(height: 44)
        .background(StudioStyle.chrome)
        .overlay(alignment: .top) { StudioStyle.hairline.frame(height: 1) }
    }

    @ViewBuilder private var inOutChip: some View {
        if let io = model.playback.inOut {
            Button { model.perform(.goIn) } label: {
                HStack(spacing: StudioStyle.Space.xs) {
                    Text("In \(StudioTime.short(io.lowerBound))")
                    Image(systemName: "arrow.right").imageScale(.small)
                    Text("Out \(StudioTime.short(io.upperBound))")
                }
                .font(StudioStyle.Fonts.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(StudioStyle.accent)
                .padding(.horizontal, StudioStyle.Space.s).padding(.vertical, 3)
                .background(StudioStyle.accent.opacity(0.12), in: StudioStyle.rounded(StudioStyle.Radius.small))
            }
            .buttonStyle(.plain)
            .help("Range \(StudioTime.compact(io.upperBound - io.lowerBound)). Click to go to In. ⌥X clears it.")
        }
    }

    private func transportButton(_ symbol: String, help: String, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(prominent ? StudioStyle.Fonts.title : StudioStyle.Fonts.body)
                .frame(width: prominent ? 34 : 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(prominent ? .primary : .secondary)
        .help(help)
    }
}

/// Reads `t` (60 Hz while playing), isolated from the rest of the bar.
struct TransportTimecode: View {
    var engine: PlaybackEngine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioStyle.Space.xs) {
            Text(StudioTime.transport(engine.t, fps: engine.fps))
                .font(StudioStyle.Fonts.timecodeLarge)
                .foregroundStyle(.primary)
            Text("/ \(StudioTime.transport(engine.duration, fps: engine.fps))")
                .font(StudioStyle.Fonts.callout)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .help("\(StudioTime.frameHelp(engine.t, fps: engine.fps)). Press I and O to set a range.")
    }
}
