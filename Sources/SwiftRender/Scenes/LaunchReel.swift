import SwiftUI

/// Full launch reel — chains all six scenes with overlapping cross-fades.
/// Pure function of t.
public struct LaunchReel: RenderScene {
    public static let defaultDuration: Double = 29.0

    private struct Act {
        let name: String
        let start: Double
        let duration: Double
        let fadeIn: Double
        let fadeOut: Double
        var end: Double { start + duration }
    }

    private static let acts: [Act] = [
        Act(name: "Hero",      start:  0.0, duration: 6.0, fadeIn: 0.0, fadeOut: 0.6),
        Act(name: "Notch",     start:  5.4, duration: 6.0, fadeIn: 0.6, fadeOut: 0.6),
        Act(name: "Waveform",  start: 10.8, duration: 4.0, fadeIn: 0.6, fadeOut: 0.6),
        Act(name: "Vinyl",     start: 14.2, duration: 6.0, fadeIn: 0.6, fadeOut: 0.6),
        Act(name: "Dahlia",    start: 19.6, duration: 4.0, fadeIn: 0.6, fadeOut: 0.6),
        Act(name: "Welcome",   start: 23.0, duration: 6.0, fadeIn: 0.6, fadeOut: 0.0),
    ]

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ForEach(Array(acts.enumerated()), id: \.offset) { _, act in
                let local = t - act.start
                let inP = Ease.easeOut(Ease.clip(local, 0.0, max(act.fadeIn, 0.001)))
                let outP = Ease.easeIn(Ease.clip(local, act.duration - act.fadeOut, act.duration))
                let opacity = (act.fadeIn > 0 ? inP : 1.0) * (1.0 - outP)
                let active = local >= -0.05 && local <= act.duration + 0.05

                if active {
                    actBody(act, localT: local)
                        .opacity(opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    @MainActor
    private static func actBody(_ act: Act, localT: Double) -> some View {
        switch act.name {
        case "Hero":     LogoReveal.body(at: localT, duration: act.duration)
        case "Notch":    NotchRecording.body(at: localT, duration: act.duration)
        case "Waveform": WaveformDance.body(at: localT, duration: act.duration)
        case "Vinyl":    VinylSpin.body(at: localT, duration: act.duration)
        case "Dahlia":   DahliaProcessing.body(at: localT, duration: act.duration)
        case "Welcome":  WelcomeSplash.body(at: localT, duration: act.duration)
        default:         EmptyView()
        }
    }
}
