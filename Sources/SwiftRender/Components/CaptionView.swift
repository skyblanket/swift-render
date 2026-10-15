import SwiftUI

/// Burned-in captions for a `CaptionTrack`, with optional karaoke word highlight.
///
///     static let captions = CaptionTrack(soundtrack(duration: defaultDuration)!)
///     …
///     CaptionView(captions, at: t)
///         .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
public struct CaptionView: View {
    /// `.karaoke` highlights the current word; `.plain` shows the cue as one colour.
    public enum Style: Sendable { case karaoke, plain }

    let track: CaptionTrack
    let t: Double
    var style: Style
    var font: Font
    var color: Color
    var highlight: Color
    var plate: Bool

    /// Shows the cue active at `t`; `plate` draws a dark rounded backing.
    public init(_ track: CaptionTrack, at t: Double, style: Style = .karaoke,
                font: Font = .system(size: 52, weight: .semibold),
                color: Color = .white, highlight: Color = Color(red: 1.0, green: 0.84, blue: 0.36),
                plate: Bool = true) {
        self.track = track; self.t = t; self.style = style; self.font = font
        self.color = color; self.highlight = highlight; self.plate = plate
    }

    /// The current cue, faded and lifted in; empty between cues.
    public var body: some View {
        if let cue = track.cue(at: t) {
            let inP = min(1, max(0, (t - cue.start + 0.08) / 0.12))
            line(cue)
                .font(font)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background {
                    if plate { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)) }
                }
                .opacity(inP)
                .offset(y: (1 - inP) * 10)
        }
    }

    private func line(_ cue: CaptionCue) -> Text {
        cue.words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let spoken = t >= w.start
            let tint: Color = style == .plain ? color : (spoken ? (t < w.end ? highlight : color) : color.opacity(0.45))
            return acc + Text((i == 0 ? "" : " ") + w.text).foregroundColor(tint)
        }
    }
}
