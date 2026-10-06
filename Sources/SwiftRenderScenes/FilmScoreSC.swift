import SwiftUI
import SwiftRender

/// FilmScoreSC v2 — the swarm-code terminal film score, rebuilt after v1 read as
/// sparse dry snaps. Design: CONTINUOUS bed (layered evolving pad) + a constant
/// 80bpm server-room heartbeat + machine-room tick texture, so punctuation lands
/// against music, not silence. Dead air is now earned (only before DENIED).
public struct FilmScoreSC: RenderScene {
    public static let defaultDuration: Double = 62.0

    public static func soundtrack(duration: Double) -> Score? {
        let beat = 0.75   // 80 bpm — the film's heartbeat
        return Score(duration: duration) {
            // ─── PAD: three octave layers + detunes, evolving, NEVER absent ─
            drone(.a1, from: 0.0, for: 25.7, amp: 0.09)
            drone(Note(56.2), from: 0.0, for: 25.7, amp: 0.055)     // slow beat vs 55
            drone(.e2, from: 4.0, for: 21.7, amp: 0.05)
            drone(Note(110.0), from: 10.0, for: 14.0, amp: 0.035)
            // dead air 25.7–26.2: EVERYTHING stops before the refusal
            drone(.e1, from: 26.2, for: 4.8, amp: 0.10)             // DENIED aftermath: low & dark
            drone(Note(41.9), from: 26.2, for: 4.8, amp: 0.06)
            drone(.a1, from: 31.0, for: 24.9, amp: 0.10)            // resolve back to root
            drone(Note(55.7), from: 31.0, for: 24.9, amp: 0.05)
            drone(.e2, from: 31.0, for: 24.9, amp: 0.06)
            drone(Note(110.0), from: 43.5, for: 12.4, amp: 0.04)    // lift under numbers→install
            drone(.a1, from: 55.9, for: 6.1, amp: 0.115)            // lockup: full chord
            drone(.e2, from: 55.9, for: 6.1, amp: 0.075)
            drone(Note(110.0), from: 55.9, for: 5.6, amp: 0.05)

            // ─── HEARTBEAT: soft kick every beat — the glue (drops for drama) ─
            every(beat, from: 2.25, to: 25.5) { t in kick(at: t, amp: 0.22) }
            every(beat, from: 27.0, to: 55.5) { t in kick(at: t, amp: 0.24) }
            every(beat, from: 55.9, to: 60.2) { t in kick(at: t, amp: 0.18) }
            // backbeat breath: every 4th beat a soft low bass touch
            every(beat * 4, from: 3.0, to: 25.5) { t in bass(.a1, at: t, duration: 0.55, amp: 0.12) }
            every(beat * 4, from: 27.75, to: 55.5) { t in
                bass([Note.a1, .e1, .g1, .a1][Int(t / 3.0) % 4], at: t, duration: 0.55, amp: 0.13)
            }

            // ─── MACHINE ROOM: continuous soft tick texture (no more silence) ─
            every(0.1875, from: 0.0, to: 25.6) { t in
                h(t * 2.3) < 0.62 ? hat(at: t, amp: 0.018 + 0.014 * h(t * 7.1), pan: (h(t * 1.7) * 2 - 1) * 0.55) : []
            }
            every(0.1875, from: 26.4, to: 60.4) { t in
                h(t * 2.9) < 0.66 ? hat(at: t, amp: 0.02 + 0.014 * h(t * 6.3), pan: (h(t * 1.3) * 2 - 1) * 0.6) : []
            }

            // ─── TYPING: key ticks slightly louder than the room ─────────────
            every(0.09, from: 0.9, to: 1.5) { t in hat(at: t, amp: 0.045, pan: -0.15) }
            every(0.05, from: 10.2, to: 11.4) { t in
                h(t * 5.1) > 0.25 ? hat(at: t, amp: 0.04, pan: -0.15) : []
            }
            every(0.06, from: 17.2, to: 18.0) { t in hat(at: t, amp: 0.04, pan: -0.15) }
            every(0.05, from: 24.2, to: 25.2) { t in
                h(t * 4.7) > 0.25 ? hat(at: t, amp: 0.042, pan: -0.15) : []
            }
            every(0.045, from: 49.7, to: 51.9) { t in
                h(t * 5.3) > 0.2 ? hat(at: t, amp: 0.038, pan: -0.15) : []
            }
            every(0.09, from: 53.1, to: 53.7) { t in hat(at: t, amp: 0.042, pan: -0.15) }

            // ─── PRINTS: soft hat pairs (claps retired from this job) ────────
            every(0.3, from: 1.8, to: 3.0) { t in hat(at: t, amp: 0.05, pan: -0.08) }
            bass(.a2, at: 3.0, duration: 0.5, amp: 0.14)             // ready.
            every(0.7, from: 11.8, to: 13.9) { t in hat(at: t, amp: 0.055, pan: -0.08) }
            kick(at: 15.2, amp: 0.42); bass(.a2, at: 15.22, duration: 0.6, amp: 0.2)  // ✓ 88 passed
            every(0.22, from: 18.8, to: 22.4) { t in                 // pane streams, panned
                h(t * 3.1) < 0.55 ? hat(at: t, amp: 0.04, pan: [-0.55, 0.0, 0.55][Int(h(t * 7.7) * 3) % 3]) : []
            }
            bass(.g2, at: 20.9, duration: 0.5, amp: 0.13)            // pane 2 done
            every(0.35, from: 37.9, to: 40.4) { t in hat(at: t, amp: 0.055, pan: -0.05) }
            bass(.a2, at: 52.9, duration: 0.5, amp: 0.14)            // installed.

            // ─── STRUCTURE ───────────────────────────────────────────────────
            kick(at: 4.0, amp: 0.4)
                      // strike
            kick(at: 6.2, amp: 0.5); bass(.e1, at: 6.2, duration: 0.9, amp: 0.22) // "3 MB"
            kick(at: 10.0, amp: 0.4)
            kick(at: 17.0, amp: 0.4)
                      // THE SPLIT
            kick(at: 18.5, amp: 0.4); kick(at: 18.62, amp: 0.34); kick(at: 18.74, amp: 0.34)
            kick(at: 24.0, amp: 0.4)
                                        // tension INTO the cut-out
            // 25.7–26.2 total silence …then:
            clap(at: 26.2, amp: 0.5, pan: 0)                                     // THE REFUSAL
            boom(at: 26.2, amp: 0.75, duration: 1.8)
            bass(.e1, at: 26.25, duration: 1.4, amp: 0.32)
            kick(at: 27.8, amp: 0.35)
            kick(at: 31.0, amp: 0.4)
            kick(at: 37.5, amp: 0.4)
            kick(at: 43.5, amp: 0.55); bass(.a1, at: 43.5, duration: 0.8, amp: 0.3)   // stats
            kick(at: 45.5, amp: 0.55); bass(.c2, at: 45.5, duration: 0.8, amp: 0.3)
            kick(at: 47.5, amp: 0.55); bass(.e2, at: 47.5, duration: 0.8, amp: 0.3)
            kick(at: 49.5, amp: 0.4)
            boom(at: 55.9, amp: 0.9, duration: 2.6)                              // lockup
            kick(at: 55.9, amp: 0.55)

            // ─── the ant crosses: chitter pans L→R over the resolving chord ──
            every(0.16, from: 56.6, to: 61.0) { t in
                h(t * 2.9) < 0.55 ? hat(at: t, amp: 0.045, pan: -0.6 + (t - 56.6) / 4.4 * 1.2) : []
            }
            hat(at: 61.5, amp: 0.05, pan: 0.55)
        }
    }

    static func h(_ x: Double) -> Double { BugRig.hash01(x) }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
