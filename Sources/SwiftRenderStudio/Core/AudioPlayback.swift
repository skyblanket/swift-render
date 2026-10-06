import AVFoundation
import Foundation

// MARK: - Audio playback (the master clock while playing forward)
//
// Anchored to the output device clock: t = t0 + (deviceCurrentTime − startDevice) × rate.
// Smoother than polling `player.currentTime`, which steps in buffer-sized jumps.
// Reverse and >2× shuttle are silent and run on the wall clock instead.

@MainActor
final class AudioPlayback {
    private var player: AVAudioPlayer?
    private(set) var url: URL?
    private var t0 = 0.0
    private var startDevice = 0.0
    private var rate = 1.0
    private(set) var isPlaying = false
    var volume: Float = 1 { didSet { player?.volume = volume } }

    var hasAudio: Bool { player != nil }
    var duration: Double { player?.duration ?? 0 }

    /// Load (or replace, e.g. after an `audio` event) the soundtrack; keeps playing from `t` if it was.
    func load(_ url: URL?, at t: Double) {
        guard url != self.url else { return }
        let wasPlaying = isPlaying
        let r = rate
        stop()
        self.url = url
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.enableRate = true
        player?.volume = volume
        player?.prepareToPlay()
        if wasPlaying { _ = play(from: t, rate: r) }
    }

    /// Whether audio can follow this rate (forward 0.5–2×).
    static func canFollow(rate: Double) -> Bool { rate >= 0.5 && rate <= 2 }

    /// Starts audio at `t`; false when there is no audio or the rate isn't followable.
    @discardableResult
    func play(from t: Double, rate: Double) -> Bool {
        guard let player, Self.canFollow(rate: rate), t < player.duration else { stop(); return false }
        player.pause()
        player.rate = Float(rate)
        player.currentTime = t
        t0 = t
        self.rate = rate
        startDevice = player.deviceCurrentTime + 0.05
        player.play(atTime: startDevice)
        isPlaying = true
        return true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    /// Scene time per the device clock, or nil when audio isn't driving.
    var clock: Double? {
        guard isPlaying, let player else { return nil }
        if !player.isPlaying && player.deviceCurrentTime > startDevice + 0.1 { return nil }   // ran off the end
        return t0 + max(0, player.deviceCurrentTime - startDevice) * rate
    }
}
