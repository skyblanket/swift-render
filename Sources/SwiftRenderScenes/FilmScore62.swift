import SwiftUI
import SwiftRender

/// FilmScore62 — audio-only stub: the SwarmRT film score re-timed to the 62s
/// HyperFrames cut list. Exists solely for `swc-render audio` WAV export;
/// the body is a blank frame and is never rendered as video.
public struct FilmScore62: RenderScene {
    public static let defaultDuration: Double = 62.0

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            // ─── BED ────────────────────────────────────────────────────
            drone(Note(92.0), from: 0.0, for: 15.5, amp: 0.05)
            drone(Note(95.5), from: 0.3, for: 15.2, amp: 0.045)
            drone(Note(46.0), from: 10.5, for: 5.0, amp: 0.06)
            drone(.a1, from: 15.5, for: 5.0, amp: 0.08)
            drone(Note(56.5), from: 15.5, for: 5.0, amp: 0.04)
            drone(.e1, from: 20.5, for: 7.0, amp: 0.05)
            drone(Note(41.9), from: 20.5, for: 7.0, amp: 0.03)
            drone(Note(82.4), from: 27.5, for: 1.6, amp: 0.06)   // tension → dead air at 29.1
            drone(Note(84.5), from: 27.5, for: 1.6, amp: 0.05)
            drone(.a1, from: 30.2, for: 4.3, amp: 0.06)
            drone(.a1, from: 34.5, for: 19.0, amp: 0.07)
            drone(.e2, from: 34.5, for: 19.0, amp: 0.05)
            drone(.a2, from: 53.5, for: 3.7, amp: 0.04)
            drone(.a1, from: 57.2, for: 4.6, amp: 0.07)
            drone(.e2, from: 57.2, for: 4.6, amp: 0.05)

            // ─── INSECT FOLEY ───────────────────────────────────────────
            every(0.23, from: 0.3, to: 2.2) { t in
                h(t) > 0.55 ? hat(at: t, amp: 0.05, pan: -0.25 + (h(t * 3.1) - 0.5) * 0.2) : []
            }
            hat(at: 2.35, amp: 0.06, pan: -0.22)   // antennae twitch at the label
            hat(at: 2.46, amp: 0.06, pan: -0.18)
            every(0.34, from: 4.7, to: 10.5) { t in
                h(t * 1.3) > 0.62 ? hat(at: t, amp: 0.04, pan: -0.4 + (h(t * 3.7) - 0.5) * 0.3) : []
            }
            every(0.16, from: 10.7, to: 15.5) { t in
                h(t) < (t - 10.5) / 5.0 ? hat(at: t, amp: 0.06, pan: (h(t * 1.7) * 2 - 1) * 0.8) : []
            }
            every(0.09, from: 13.4, to: 15.5) { t in
                h(t * 2.9) < 0.5 ? hat(at: t, amp: 0.05, pan: (h(t * 0.7) * 2 - 1) * 0.9) : []
            }
            every(0.13, from: 15.7, to: 20.5) { t in
                h(t * 2.3) < 0.55 ? hat(at: t, amp: 0.05, pan: (h(t * 1.9) * 2 - 1) * 0.7) : []
            }
            every(0.2, from: 20.5, to: 27.5) { t in
                h(t * 3.3) < 0.2 ? hat(at: t, amp: 0.035, pan: (h(t * 1.1) * 2 - 1) * 0.6) : []
            }
            every(0.12, from: 27.5, to: 29.1) { t in    // hard stop → 0.4s silence
                h(t * 2.1) < 0.6 ? hat(at: t, amp: 0.055, pan: (h(t * 1.5) * 2 - 1) * 0.7) : []
            }
            hat(at: 31.20, amp: 0.07, pan: -0.6)        // replacement scurries in
            hat(at: 31.27, amp: 0.07, pan: -0.4)
            hat(at: 31.35, amp: 0.06, pan: -0.2)
            hat(at: 31.44, amp: 0.06, pan: 0.0)
            every(0.12, from: 30.4, to: 34.5) { t in
                h(t * 2.7) < 0.55 ? hat(at: t, amp: 0.05, pan: (h(t * 1.3) * 2 - 1) * 0.7) : []
            }
            every(0.14, from: 34.5, to: 53.5) { t in
                h(t * 1.9) < 0.45 ? hat(at: t, amp: 0.05, pan: (h(t * 0.9) * 2 - 1) * 0.75) : []
            }
            every(0.15, from: 53.5, to: 60.2) { t in
                h(t * 2.4) < 0.4 ? hat(at: t, amp: 0.045, pan: (h(t * 1.6) * 2 - 1) * 0.7) : []
            }
            every(0.11, from: 60.25, to: 61.35) { t in
                h(t * 3.7) < (61.7 - t) / 1.4 * 0.7 ? hat(at: t, amp: 0.04, pan: (h(t * 1.3) * 2 - 1) * 0.95) : []
            }
            hat(at: 61.5, amp: 0.06, pan: 0.4)          // last lone click

            // ─── TYPE MECHANICS ─────────────────────────────────────────
            every(0.07, from: 1.9, to: 4.1) { t in hat(at: t, amp: 0.02, pan: 0.2) }
            every(0.06, from: 4.7, to: 6.4) { t in hat(at: t, amp: 0.02, pan: 0.1) }
            every(0.055, from: 11.1, to: 12.4) { t in hat(at: t, amp: 0.02, pan: 0.25) }
            every(0.032, from: 21.2, to: 24.9) { t in
                h(t * 7.3) > 0.2 ? hat(at: t, amp: 0.022, pan: 0.12) : []
            }
            clap(at: 22.1, amp: 0.1, pan: 0.15)         // code carriage returns
            clap(at: 22.8, amp: 0.1, pan: 0.15)
            clap(at: 23.7, amp: 0.1, pan: 0.15)
            clap(at: 24.4, amp: 0.1, pan: 0.15)
            clap(at: 24.65, amp: 0.1, pan: 0.15)
            clap(at: 24.9, amp: 0.12, pan: 0.15)
            every(0.7, from: 41.5, to: 45.4) { t in     // checklist rows
                hat(at: t, amp: 0.03, pan: -0.15)
                    + hat(at: t + 0.06, amp: 0.03, pan: -0.1)
                    + hat(at: t + 0.13, amp: 0.03, pan: -0.05)
                    + clap(at: t + 0.3, amp: 0.2, pan: (h(t) - 0.5) * 0.5)
            }
            clap(at: 46.3, amp: 0.15, pan: 0)           // "batteries in the binary."
            every(0.05, from: 53.7, to: 55.7) { t in
                h(t * 5.1) > 0.15 ? hat(at: t, amp: 0.025, pan: -0.1) : []
            }
            clap(at: 55.72, amp: 0.12, pan: -0.1)       // return key
            clap(at: 56.0, amp: 0.22, pan: 0)           // success line
            hat(at: 56.0, amp: 0.05, pan: 0)

            // ─── PUNCTUATION — two booms total ──────────────────────────
            kick(at: 4.5, amp: 0.4); clap(at: 4.5, amp: 0.3, pan: 0)
            clap(at: 7.02, amp: 0.25, pan: -0.1)
            clap(at: 8.02, amp: 0.25, pan: 0.1)
            clap(at: 9.02, amp: 0.25, pan: -0.1)
            kick(at: 9.5, amp: 0.5); clap(at: 9.5, amp: 0.35, pan: 0)   // red chip
            kick(at: 10.5, amp: 0.4); clap(at: 10.5, amp: 0.3, pan: 0)
            every(0.05, from: 10.8, to: 14.0) { t in
                h(t * 4.3) < 0.5 ? hat(at: t, amp: 0.02, pan: 0.25) : []
            }
            boom(at: 15.5, amp: 0.85, duration: 2.4)                    // BOOM #1 wordmark
            kick(at: 15.5, amp: 0.6); clap(at: 15.5, amp: 0.35, pan: 0)
            kick(at: 20.5, amp: 0.4); clap(at: 20.5, amp: 0.3, pan: 0)
            kick(at: 27.5, amp: 0.4); clap(at: 27.5, amp: 0.3, pan: 0)
            clap(at: 29.5, amp: 0.5, pan: 0)                            // the death snap
            boom(at: 29.5, amp: 0.35, duration: 1.2)
            kick(at: 30.3, amp: 0.3)
            kick(at: 30.9, amp: 0.25)
            kick(at: 31.5, amp: 0.2)
            kick(at: 34.5, amp: 0.55); clap(at: 34.5, amp: 0.3, pan: 0)
            bass(.a1, at: 34.5, duration: 0.8, amp: 0.3)
            kick(at: 36.67, amp: 0.55); clap(at: 36.67, amp: 0.3, pan: 0)
            bass(.c2, at: 36.67, duration: 0.8, amp: 0.3)
            kick(at: 38.83, amp: 0.55); clap(at: 38.83, amp: 0.3, pan: 0)
            bass(.e2, at: 38.83, duration: 0.8, amp: 0.3)
            kick(at: 41.0, amp: 0.4); clap(at: 41.0, amp: 0.3, pan: 0)
            kick(at: 47.5, amp: 0.4); clap(at: 47.5, amp: 0.3, pan: 0)
            bass(.a2, at: 48.65, duration: 0.4, amp: 0.25)
            bass(.g2, at: 49.35, duration: 0.4, amp: 0.25)
            bass(.g2, at: 50.05, duration: 0.4, amp: 0.25)
            bass(.e1, at: 50.75, duration: 0.4, amp: 0.22)
            kick(at: 53.5, amp: 0.4); clap(at: 53.5, amp: 0.3, pan: 0)
            boom(at: 57.2, amp: 0.95, duration: 2.8)                    // BOOM #2 lockup
            kick(at: 57.2, amp: 0.6); clap(at: 57.2, amp: 0.4, pan: 0)
        }
    }

    static func h(_ x: Double) -> Double { BugRig.hash01(x) }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
